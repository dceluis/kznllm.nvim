local EditBlock = {}
EditBlock.__index = EditBlock

function EditBlock.new(source_map, remove_map, insert_map)
    local self = setmetatable({}, EditBlock)

    self._source_map = source_map
    self._remove_map = remove_map
    self._insert_map = insert_map
    self._mismatch = nil

    return self
end

function EditBlock:mismatch(value)
    if value ~= nil and type(value) ~= 'number' then
        error("mismatch must be a number or nil")
    end

    if value ~= nil then
        self._mismatch = value
    end

    return self._mismatch
end

function EditBlock:source_map()
    return self._source_map
end

function EditBlock:remove_map()
    return self._remove_map
end

function EditBlock:insert_map()
    return self._insert_map
end

function EditBlock:len()
    return #self._remove_map
end

function EditBlock:as_content(opts)
    opts = opts or {}
    local numbered = opts.numbered or false
    local mismatch = opts.mismatch or false

    if mismatch then
        if self._mismatch ~= nil then
            local removed = self._remove_map:get(self._mismatch)
            local source = self._source_map:get(self._mismatch)

            if numbered then
                removed = self._remove_map:as_numbered_line(removed, self._mismatch)
                source = self._source_map:as_numbered_line(source, self._mismatch)
            end

            return string.format("<<<<<<< REMOVE\n%s=======\n%s>>>>>>> SOURCE\n", removed, source)
        else
            return "ALL LINES MATCHED"
        end
    else
        local removed = self._remove_map:as_content({apply = false, numbered = numbered})
        local inserted = self._insert_map:as_content({apply = false, padded = numbered})

        return string.format("<<<<<<< REMOVE\n%s=======\n%s>>>>>>> INSERT\n", removed, inserted)
    end
end

return EditBlock
