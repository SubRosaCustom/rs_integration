local function find_file(files, path)
	for _, file in ipairs(files) do
		if file.path == path then
			return file
		end
	end
	return nil
end

return function(state, src)
	assert(find_file(state.scripts, "test.lua"))
	assert(find_file(state.assetFiles, "test.wav"))
	assert(type(state.manifestHash) == "string" and state.manifestHash:match("^[0-9a-f]+$"))
	assert(#state.manifestHash == 64)

	local client_bundle = assert(state.syncBundlesById.clientroot)
	local files = miniz.extractZip(client_bundle.archive)
	assert(files["test.lua"] == "return \"fixture\"\n")
	assert(files["test.wav"] == "fixture asset\n")

	local generation = state.syncGeneration
	local manifest_hash = state.manifestHash
	src.refreshSyncFiles()
	assert(state.syncGeneration == generation + 1)
	assert(state.manifestHash == manifest_hash)
end
