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

        --load new production lines
        ProductionLineInserter.loadAdditionalProductionLines(productionPoint, xmlFile, key, productionPoint.components, productionPoint.i3dMappings, productionPoint.customEnvironment)
        --load additional supported fillTypes for unloading station
        ProductionLineInserter.loadAdditionalSupportedFillTypes(productionPoint, xmlFile, key .. ".sellingStation")
        --load new unloadTriggers
        ProductionLineInserter.loadAdditionalUnloadTrigger(productionPoint, xmlFile, key .. ".sellingStation", productionPoint.components, productionPoint.i3dMappings, productionPoint.customEnvironment)
        --load additional loading trigger for loading station. also add new supported fillTypes. If none exist a new one can be added.
        ProductionLineInserter.loadAdditionalLoadingTrigger(productionPoint, xmlFile, key .. ".loadingStation", productionPoint.components, productionPoint.i3dMappings, productionPoint.customEnvironment)
        --load additional pallet spawner. This can add a new one if none exists. Or add additonal spawn places and fillTypes
        ProductionLineInserter.loadAdditionalPalletSpawner(productionPoint, xmlFile, key .. ".palletSpawner")
        --Load additional entries for storage
        ProductionLineInserter.loadAdditionalStorageEntries(productionPoint.storage, xmlFile, key .. ".storage", productionPoint.components, productionPoint.i3dMappings)
        --TODO, but not now: load audio for client.

        -- check if all inputs are supported
        for inputFillTypeIndex in pairs(self.inputFillTypeIds) do
            if not self.unloadingStation:getIsFillTypeSupported(inputFillTypeIndex) then
                local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(inputFillTypeIndex)

                Logging.xmlWarning(xmlFile, "Input filltype '%s' is not supported by unloading station", fillTypeName)
            end
        end

        -- check if all output fillTypes are supported
        for outputFillTypeIndex in pairs(self.outputFillTypeIds) do
            if (self.loadingStation == nil or not self.loadingStation:getIsFillTypeSupported(outputFillTypeIndex)) and self.outputFillTypeIdsToPallets[outputFillTypeIndex] == nil then
                local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(outputFillTypeIndex)

                Logging.xmlWarning(xmlFile, "Output filltype '%s' is not supported by loading station or pallet spawner", fillTypeName)
            end
        end

        for supportedFillType, _ in pairs(self.storage:getSupportedFillTypes()) do
            if not self.inputFillTypeIds[supportedFillType] and not self.outputFillTypeIds[supportedFillType] then
                Logging.xmlWarning(xmlFile, "storage fillType '%s' not used as a production input or ouput", g_fillTypeManager:getFillTypeNameByIndex(supportedFillType))
            end
        end

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

function ProductionLineInserter.loadAdditionalSupportedFillTypes(productionPoint, xmlFile, key)
    local fillTypeCategories = xmlFile:getValue(key .. "#additionalFillTypeCategories")
	local fillTypeNames = xmlFile:getValue(key .. "#additionalFillTypes")
    local self = productionPoint.unloadingStation

    if fillTypeCategories ~= nil then
        for _, fillTypeIndex in pairs(g_fillTypeManager:getFillTypesByCategoryNames(fillTypeCategories, "Warning: Additional Production has invalid fillTypeCategory '%s'.")) do
            self.supportedFillTypes[fillTypeIndex] = true
            self:addAcceptedFillType(fillTypeIndex, g_fillTypeManager:getFillTypeByIndex(fillTypeIndex).pricePerLiter, true, false)
        end
    end

    if fillTypeNames ~= nil then
        for _, fillTypeIndex in pairs(g_fillTypeManager:getFillTypesByNames(fillTypeNames, "Warning: Additional Production has invalid fillType '%s'.")) do
            self.supportedFillTypes[fillTypeIndex] = true
            self:addAcceptedFillType(fillTypeIndex, g_fillTypeManager:getFillTypeByIndex(fillTypeIndex).pricePerLiter, true, false)
        end
    end

    self:initPricingDynamics()
    self.unloadingStationDirtyFlag = self:getNextDirtyFlag()
end

function ProductionLineInserter.loadAdditionalUnloadTrigger(productionPoint, xmlFile, key, components, i3dMappings, customEnv)
    local self = productionPoint.unloadingStation
    xmlFile:iterate(key .. ".unloadTrigger", function (index, unloadTriggerKey)
		local className = xmlFile:getValue(unloadTriggerKey .. "#class", "UnloadTrigger")
		local class = ClassUtil.getClassObject(className)

		if class == nil then
			Logging.xmlError(xmlFile, "UnloadTrigger class '%s' not defined", className, unloadTriggerKey)

			return
		end

		local unloadTrigger = class.new(self.isServer, self.isClient)

		if unloadTrigger:load(components, xmlFile, unloadTriggerKey, self, nil, i3dMappings) then
			unloadTrigger:setTarget(self)
			unloadTrigger:register(true)
			table.insert(self.unloadTriggers, unloadTrigger)
		else
			unloadTrigger:delete()
		end
	end)
end

function ProductionLineInserter.loadAdditionalLoadingTrigger(productionPoint, xmlFile, key, components, i3dMappings, customEnv)
    if productionPoint.loadingStation == nil and xmlFile:hasProperty(key) then
        local self = productionPoint
        self.loadingStation = LoadingStation.new(self.isServer, self.isClient)

        if not self.loadingStation:load(components, xmlFile, key, self.customEnvironment, i3dMappings, components[1].node) then
			Logging.xmlError(xmlFile, "Unable to load loading station %s", key)

			return false
		end

		-- Lines 310-312
		function self.loadingStation.hasFarmAccessToStorage(_, farmId)
			return farmId == self.owningPlaceable:getOwnerFarmId()
		end

		self.loadingStation.owningPlaceable = self.owningPlaceable

		self.loadingStation:register(true)
    else
        local self = productionPoint.loadingStation

        xmlFile:iterate(key .. ".loadTrigger", function (_, loadTriggerKey)
            local className = xmlFile:getValue(loadTriggerKey .. "#class", "LoadTrigger")
            local class = ClassUtil.getClassObject(className)

            if class == nil then
                Logging.xmlError(xmlFile, "LoadTrigger class '%s' not defined", className, loadTriggerKey)

                return
            end

            local loadTrigger = class.new(self.isServer, self.isClient)

            if loadTrigger:load(components, xmlFile, loadTriggerKey, i3dMappings, self.rootNode) then
                loadTrigger:setSource(self)
                loadTrigger:register(true)
                table.insert(self.loadTriggers, loadTrigger)
            else
                loadTrigger:delete()
            end

            self:updateSupportedFillTypes()
	    end)
    end
end

function ProductionLineInserter.loadAdditionalPalletSpawner(productionPoint, xmlFile, key, components, i3dMappings, customEnv)
    if productionPoint.palletSpawner == nil and xmlFile:hasProperty(key) then
        local self = productionPoint
        self.palletSpawner = PalletSpawner.new(self.baseDirectory)

		if not self.palletSpawner:load(components, xmlFile, key, self.customEnvironment, i3dMappings) then
			Logging.xmlError(xmlFile, "Unable to load pallet spawner %s", key)

			return false
		end
    else
        local self = productionPoint.palletSpawner

        xmlFile:iterate(key .. ".spawnPlaces.spawnPlace", function (index, spawnPlaceKey)
            local spawnPlace = PlacementUtil.loadPlaceFromXML(xmlFile, spawnPlaceKey, components, i3dMappings)
            local fillTypes = nil
            local fillTypeCategories = xmlFile:getValue(spawnPlaceKey .. "#fillTypeCategories")
            local fillTypeNames = xmlFile:getValue(spawnPlaceKey .. "#fillTypes")

            if fillTypeCategories ~= nil and fillTypeNames == nil then
                fillTypes = g_fillTypeManager:getFillTypesByCategoryNames(fillTypeCategories, "Warning: Palletspawner '" .. xmlFile:getFilename() .. "' has invalid fillTypeCategory '%s'.")
            elseif fillTypeCategories == nil and fillTypeNames ~= nil then
                fillTypes = g_fillTypeManager:getFillTypesByNames(fillTypeNames, "Warning: Palletspawner '" .. xmlFile:getFilename() .. "' has invalid fillType '%s'.")
            end

            if fillTypes ~= nil then
                for _, fillType in ipairs(fillTypes) do
                    if self.fillTypeToSpawnPlaces[fillType] == nil then
                        self.fillTypeToSpawnPlaces[fillType] = {}
                    end

                    table.insert(self.fillTypeToSpawnPlaces[fillType], spawnPlace)
                end
            else
                table.insert(self.spawnPlaces, spawnPlace)
            end
        end)
    end

    if productionPoint.palletSpawner == nil then
        return
    end

    local self = productionPoint.palletSpawner

    --load pallets
    xmlFile:iterate(key .. ".pallets.pallet", function (index, palletKey)
		local palletFilename = Utils.getFilename(xmlFile:getValue(palletKey .. "#filename"), self.baseDirectory)

		self:loadPalletFromFilename(palletFilename)
	end)

    for fillTypeId, fillType in pairs(g_fillTypeManager.indexToFillType) do
		if fillType.palletFilename and self.fillTypeIdToPallet[fillTypeId] == nil then
			self:loadPalletFromFilename(fillType.palletFilename, fillTypeId)
		end
	end

    --update output fillType data in productionPoint
    for fillTypeId, pallet in pairs(self:getSupportedFillTypes()) do
        if productionPoint.outputFillTypeIds[fillTypeId] then
            productionPoint.outputFillTypeIdsToPallets[fillTypeId] = pallet
        end
    end
end

function ProductionLineInserter.loadAdditionalStorageEntries(storage, xmlFile, key, components, i3dMappings)
    local self = storage
    self.capacity = xmlFile:getValue(key .. "#capacity", 100000)
    self.rootNode = xmlFile:getValue(key .. "#node", components[1].node, components, i3dMappings)
	self.costsPerFillLevelAndDay = xmlFile:getValue(key .. "#costsPerFillLevelAndDay") or 0
	self.capacity = xmlFile:getValue(key .. "#capacity", 100000)
	self.fillLevelSyncThreshold = xmlFile:getValue(key .. "#fillLevelSyncThreshold", 1)
	self.supportsMultipleFillTypes = xmlFile:getValue(key .. "#supportsMultipleFillTypes", true)

    local fillTypeCategories = xmlFile:getValue(key .. "#fillTypeCategories")
	local fillTypeNames = xmlFile:getValue(key .. "#fillTypes")
	local fillTypes = nil

	if fillTypeCategories ~= nil and fillTypeNames == nil then
		fillTypes = g_fillTypeManager:getFillTypesByCategoryNames(fillTypeCategories, "Warning: '" .. tostring(key) .. "' has invalid fillTypeCategory '%s'.")
	elseif fillTypeCategories == nil and fillTypeNames ~= nil then
		fillTypes = g_fillTypeManager:getFillTypesByNames(fillTypeNames, "Warning: '" .. tostring(key) .. "' has invalid fillType '%s'.")
	end

	if fillTypes ~= nil then
		for _, fillType in pairs(fillTypes) do
			self.fillTypes[fillType] = true
		end
	end

    xmlFile:iterate(key .. ".capacity", function (_, capacityKey)
		local fillTypeName = xmlFile:getValue(capacityKey .. "#fillType")
		local fillType = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)

		if fillType ~= nil then
			self.fillTypes[fillType] = true
			local capacity = xmlFile:getValue(capacityKey .. "#capacity", 100000)
			self.capacities[fillType] = capacity
		else
			Logging.xmlWarning(xmlFile, "FillType '%s' not defined for '%s'", fillTypeName, capacityKey)
		end
	end)

    for fillType, _ in pairs(self.fillTypes) do
		table.insert(self.sortedFillTypes, fillType)

		self.fillLevels[fillType] = 0
		self.fillLevelsLastSynced[fillType] = 0
		self.fillLevelsLastPublished[fillType] = 0
	end

	table.sort(self.sortedFillTypes)

    xmlFile:iterate(key .. ".fillPlane", function (_, fillPlaneKey)
		local fillTypeName = xmlFile:getValue(fillPlaneKey .. "#fillType")
		local fillType = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)

		if fillType ~= nil then
			local fillPlane = FillPlane.new()

			fillPlane:load(components, xmlFile, fillPlaneKey, i3dMappings)

			self.fillPlanes[fillType] = fillPlane
		end
	end)

    if self.dynamicFillPlaneBaseNode ~= nil then
		local defaultFillTypeName = xmlFile:getValue(key .. ".dynamicFillPlane#defaultFillType")
		local defaultFillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(defaultFillTypeName) or self.sortedFillTypes[1]
		local fillPlane = FillPlaneUtil.createFromXML(xmlFile, key .. ".dynamicFillPlane", self.dynamicFillPlaneBaseNode, self.capacities[defaultFillTypeIndex] or self.capacity)

		if fillPlane ~= nil then
			FillPlaneUtil.assignDefaultMaterials(fillPlane)
			FillPlaneUtil.setFillType(fillPlane, defaultFillTypeIndex)

			self.dynamicFillPlane = fillPlane
		end
	end

    self.storageDirtyFlag = self:getNextDirtyFlag()
end