-- newline-framed receive buffer; each byte is scanned and copied once
local tcp_receive_buffer = {}
local Buffer = {}
Buffer.__index = Buffer

function tcp_receive_buffer.new()
	return setmetatable({
		partial = {},       -- pieces of the current unterminated line
		partial_bytes = 0,
		lines = {},         -- complete, non-empty lines
		head = 1,
		tail = 0,
		total_bytes = 0,    -- partial plus queued line bytes (delimiters excluded)
	}, Buffer)
end

-- limit covers a frame with its newline and the whole backlog; false, reason when exceeded
function Buffer:push(data, limit)
	local position = 1
	local length = #data
	while position <= length do
		local newline = data:find("\n", position, true)
		if not newline then
			local rest = length - position + 1
			if self.total_bytes + rest >= limit then
				return false, "frame exceeds limit"
			end
			self.partial[#self.partial + 1] = position == 1 and data or data:sub(position)
			self.partial_bytes = self.partial_bytes + rest
			self.total_bytes = self.total_bytes + rest
			return true
		end

		local segment_bytes = newline - position
		if self.total_bytes + segment_bytes + 1 > limit then
			return false, "frame exceeds limit"
		end
		local line
		if self.partial_bytes > 0 then
			self.partial[#self.partial + 1] = data:sub(position, newline - 1)
			line = table.concat(self.partial)
			self.partial = {}
			self.partial_bytes = 0
		else
			line = data:sub(position, newline - 1)
		end
		if line ~= "" then
			self.tail = self.tail + 1
			self.lines[self.tail] = line
			self.total_bytes = self.total_bytes + segment_bytes
		end
		position = newline + 1
	end
	return true
end

function Buffer:pop_line()
	if self.head > self.tail then
		return nil
	end
	local line = self.lines[self.head]
	self.lines[self.head] = nil
	self.head = self.head + 1
	if self.head > self.tail then
		self.head, self.tail = 1, 0
	end
	self.total_bytes = self.total_bytes - #line
	return line
end

return tcp_receive_buffer
