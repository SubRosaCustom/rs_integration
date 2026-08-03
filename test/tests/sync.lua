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
	assert(find_file(state.asset_files, "test.wav"))
	assert(type(state.manifest_hash) == "string" and state.manifest_hash:match("^[0-9a-f]+$"))
	assert(#state.manifest_hash == 64)

	local client_bundle = assert(state.sync_bundles_by_id.clientroot)
	local files = miniz.extractZip(client_bundle.archive)
	assert(files["test.lua"] == "return \"fixture\"\n")
	assert(files["test.wav"] == "fixture asset\n")

	local generation = state.sync_generation
	local manifest_hash = state.manifest_hash
	src.refreshSyncFiles()
	assert(state.sync_generation == generation + 1)
	assert(state.manifest_hash == manifest_hash)
end
