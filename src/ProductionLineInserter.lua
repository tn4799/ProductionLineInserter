ProductionLineInserter = {
    MOD_DIR = g_currentModDirectory,
    FILENAME = Utils.getFilename("xml/AdditionalProductionLines.xml", g_currentModDirectory),
    BASE_KEY = "additionalProductionLines.additionalProductionLine"
}

function ProductionLineInserter:loadXMLFile()
    local xmlFile = XmlFile.load("AdditionalProductionLinesXML", ProductionLineInserter.FILENAME)

    if xmlFile == nil then
        Logging.error("Could not find file '%s'", ProductionLineInserter.FILENAME)

        return
    end

    xmlFile:iterate(ProductionLineInserter.BASE_KEY, function (idx, key)
        local productionFilename = Utils.getFilename(xmlFile:getString(key .. "#filename"))
        local isDlcProduction = xmlFile:getBool(key .. "#isDlc", false)
        local modName = xmlFile:getString(key .. "#modName")
        local storeItem

        if isDlcProduction then
            for _, dlcDirectory in  g_dlcDirectories do
                local path = dlcDirectory.path
                local name = Utils.getFilename(productionFilename, path)
                local item = g_storeManager:getItemByXMLFilename(name)

                if item ~= nil then
                    storeItem = item
                    productionFilename = name
                    break
                end
            end
        elseif modName ~= nil then
            local name = Utils.getFilename(productionFilename, g_modsDirectory .. "/" .. modName)
            local item = g_storeManager:getItemByXMLFilename(name)

            if item ~= nil then
                storeItem = item
                productionFilename = name
            end
        else
            storeItem = g_storeManager:getItemByXMLFilename(productionFilename)
        end

        if storeItem == nil then
            Logging.warning("Item %s not found. Skipping", productionFilename)
            goto continue
        end

        local productionPoint = ProductionLineInserter.findProductionPointToFilename(productionFilename)

        if productionPoint == nil then
            Logging.error("Production Point not found. Cannot insert additional production lines")
            goto continue
        end

        key = key .. ".productionPoint"

        ProductionLineInserter.loadAdditionalProductionLines(productionPoint, xmlFile, key, productionPoint.components, productionPoint.i3dMappings, productionPoint.customEnvironment)

        --TODO: load loadingStation
        --TODO: load storage
        --TODO: load unloading station
        --TODO: load pallet spawner
        --TODO: load audio for client

        ::continue::
    end)
end

function ProductionLineInserter.findProductionPointToFilename(filename)
    local placeables = g_currentMission.placeableSytem.placeables

    for _, placeable in pairs(placeables) do
        if placeable.configFileName == filename then
            local productionPointSpec = g_placeableSpecializationManager:getSpecializationObjectByName("productionPoint")

            if not SpecializationUtil.hasSpecialzation(productionPointSpec, placeable.specializations) then
                Logging.error("%s is no productionPoint. Can't add an additional production line")

                return nil
            end

            return placeable.spec_productionPoint.productionPoint
        end
    end

    return nil
end

function ProductionLineInserter.loadAdditionalProductionLines(productionPoint, xmlFile, key, components, i3dMappings, customEnv)
    xmlFile:iterate(key .. ".productions.production", function (index, productionKey)
		local production = {
			id = xmlFile:getValue(productionKey .. "#id"),
			name = xmlFile:getValue(productionKey .. "#name", nil, customEnv, false)
		}
		local params = xmlFile:getValue(productionKey .. "#params")

		if params ~= nil then
			params = params:split("|")

			for i = 1, #params do
				params[i] = g_i18n:convertText(params[i], customEnv)
			end

			production.name = string.format(production.name, unpack(params))
		end

		if not production.id then
			Logging.xmlError(xmlFile, "missing id for production '%s'", production.name or index)

			return false
		end

		for i = 1, #usedProdIds do
			if usedProdIds[i] == production.id then
				Logging.xmlError(xmlFile, "production id '%s' already in use", production.id)

				return false
			end
		end

		table.insert(usedProdIds, production.id)

		local cyclesPerMonth = xmlFile:getValue(productionKey .. "#cyclesPerMonth")
		local cyclesPerHour = xmlFile:getValue(productionKey .. "#cyclesPerHour")
		local cyclesPerMinute = xmlFile:getValue(productionKey .. "#cyclesPerMinute")
		production.cyclesPerMinute = cyclesPerMonth and cyclesPerMonth / 60 / 24 or cyclesPerHour and cyclesPerHour / 60 or cyclesPerMinute or 1
		production.cyclesPerHour = cyclesPerHour or production.cyclesPerMinute * 60
		production.cyclesPerMonth = cyclesPerMonth or production.cyclesPerHour * 24
		local costsPerActiveMinute = xmlFile:getValue(productionKey .. "#costsPerActiveMinute")
		local costsPerActiveHour = xmlFile:getValue(productionKey .. "#costsPerActiveHour")
		local costsPerActiveMonth = xmlFile:getValue(productionKey .. "#costsPerActiveMonth")
		production.costsPerActiveMinute = costsPerActiveMonth and costsPerActiveMonth / 60 / 24 or costsPerActiveHour and costsPerActiveHour / 60 or costsPerActiveMinute or 1
		production.costsPerActiveHour = costsPerActiveHour or production.costsPerActiveMinute * 60
		production.costsPerActiveMonth = costsPerActiveMonth or production.costsPerActiveHour * 24
		production.status = ProductionPoint.PROD_STATUS.INACTIVE
		production.inputs = {}

		xmlFile:iterate(productionKey .. ".inputs.input", function (inputIndex, inputKey)
			local input = {}
			local fillTypeString = xmlFile:getValue(inputKey .. "#fillType")
			input.type = g_fillTypeManager:getFillTypeIndexByName(fillTypeString)

			if input.type == nil then
				Logging.xmlError(xmlFile, "Unable to load fillType '%s' for '%s'", fillTypeString, inputKey)
			else
				productionPoint.inputFillTypeIds[input.type] = true

				table.addElement(productionPoint.inputFillTypeIdsArray, input.type)

				input.amount = xmlFile:getValue(inputKey .. "#amount", 1)

				table.insert(production.inputs, input)
			end
		end)

		if #production.inputs == 0 then
			Logging.xmlError(xmlFile, "No inputs for production '%s'", productionKey)

			return
		end

		production.outputs = {}
		production.primaryProductFillType = nil
		local maxOutputAmount = 0

		xmlFile:iterate(productionKey .. ".outputs.output", function (outputIndex, outputKey)
			local output = {}
			local fillTypeString = xmlFile:getValue(outputKey .. "#fillType")
			output.type = g_fillTypeManager:getFillTypeIndexByName(fillTypeString)

			if output.type == nil then
				Logging.xmlError(xmlFile, "Unable to load fillType '%s' for '%s'", fillTypeString, outputKey)
			else
				output.sellDirectly = xmlFile:getValue(outputKey .. "#sellDirectly", false)

				if not output.sellDirectly then
					productionPoint.outputFillTypeIds[output.type] = true

					table.addElement(productionPoint.outputFillTypeIdsArray, output.type)
				else
					productionPoint.soldFillTypesToPayOut[output.type] = 0
				end

				output.amount = xmlFile:getValue(outputKey .. "#amount", 1)

				table.insert(production.outputs, output)

				if maxOutputAmount < output.amount then
					production.primaryProductFillType = output.type
					maxOutputAmount = output.amount
				end
			end
		end)

		if #production.outputs == 0 then
			Logging.xmlError(xmlFile, "No outputs for production '%s'", productionKey)
		end

		if productionPoint.isClient then
			production.samples = {
				active = g_soundManager:loadSampleFromXML(xmlFile, productionKey .. ".sounds", "active", productionPoint.baseDirectory, components, 1, AudioGroup.ENVIRONMENT, i3dMappings, nil)
			}
			production.animationNodes = g_animationManager:loadAnimations(xmlFile, productionKey .. ".animationNodes", components, productionPoint, i3dMappings)
			production.effects = g_effectManager:loadEffect(xmlFile, productionKey .. ".effectNodes", components, productionPoint, i3dMappings)

			g_effectManager:setFillType(production.effects, FillType.UNKNOWN)
		end

		if productionPoint.productionsIdToObj[production.id] ~= nil then
			Logging.xmlError(xmlFile, "Error: production id '%s' already used", production.id)

			return false
		end

		productionPoint.productionsIdToObj[production.id] = production

		table.insert(productionPoint.productions, production)

		return true
	end)
end