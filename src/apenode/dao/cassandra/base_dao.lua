-- Copyright (C) Mashape, Inc.

local dao_utils = require "apenode.dao.dao_utils"
local Object = require "classic"
local utils = require "apenode.tools.utils"
local uuid = require "uuid"
local cassandra = require "cassandra"
require "stringy"

-- This is important to seed the UUID generator
uuid.seed()

local BaseDao = Object:extend()

function BaseDao:new(client, collection, schema)
  self._configuration = configuration
  self._collection = collection
  self._schema = schema

  -- Cache the prepared statements if already prepared
  self._client = client
end

-- Utility function to create query fields and values from an entity, useful for save and update
-- @param entity The entity whose fields needs to be parsed
-- @return A list of fields, of values placeholders, and the actual values table
local function get_cmd_args(entity, update)
  local cmd_field_values = {}
  local cmd_fields = {}
  local cmd_values = {}

  if update then
    entity.id = nil
    entity.created_at = nil
  end

  for k, v in pairs(entity) do
    table.insert(cmd_fields, k)
    table.insert(cmd_values, "?")
    if type(v) == "table" then
      table.insert(cmd_field_values, cassandra.list(v))
    elseif k == "created_at" or k == "timestamp" then
      local _created_at = v
      if string.len(tostring(_created_at)) == 10 then
        _created_at = _created_at * 1000 -- Convert to milliseconds
      end
      table.insert(cmd_field_values, cassandra.timestamp(_created_at))
    elseif stringy.endswith(k, "id") then
      table.insert(cmd_field_values, cassandra.uuid(v))
    else
      table.insert(cmd_field_values, v)
    end
  end

  return table.concat(cmd_fields, ","), table.concat(cmd_values, ","), cmd_field_values
end

-- Utility function to get where arguments
-- @param entity The entity whose fields needs to be parsed
-- @return A list of fields for the where clause, and the actual values table
function BaseDao._get_where_args(entity)
  if utils.table_size(entity) == 0 then
    return nil, nil
  end

  local cmd_fields, cmd_values, cmd_field_values = get_cmd_args(entity, false)

  local result = {}
  local args = stringy.split(cmd_fields, ",")
  for _,v in ipairs(args) do
    table.insert(result, v .. "=?")
  end

  return table.concat(result, " AND "), cmd_field_values
end

-- Insert an entity
-- @param table entity Entity to insert
-- @return table Inserted entity with its rowid property
-- @return table Error if error
function BaseDao:insert(entity)
  if entity then
    entity = dao_utils.serialize(self._schema, entity)
  else
    return nil
  end

  -- Set an UUID as the ID of the entity
  if not entity.id then
    entity.id = uuid()
  end

  -- Prepare the command
  local cmd_fields, cmd_values, cmd_field_values = get_cmd_args(entity, false)

  -- Execute the command
  local cmd = "INSERT INTO " .. self._collection .. " (" .. cmd_fields .. ") VALUES (" .. cmd_values .. ")"

  local result, err = self._client:query(cmd, cmd_field_values)
  return entity
end

-- Update one or many entities according to a WHERE statement
-- @param table entity Entity to update
-- @return table Updated entity
-- @return table Error if error
function BaseDao:update(entity)
  if entity and utils.table_size(entity) > 0 then
    entity = dao_utils.serialize(self._schema, entity)
  else
    return 0
  end

  local where_keys = {
    id = entity.id
  }

  local cmd_entity_fields, cmd_entity_values = BaseDao._get_where_args(entity)
  local cmd_where_fields, cmd_where_values = BaseDao._get_where_args(where_keys)

  local cmd = "UPDATE " .. self._collection .. " SET " .. cmd_entity_fields .. " WHERE " .. cmd_where_fields

  -- Merging tables
  for k,v in pairs(cmd_where_values) do
    --TODO: Maybe we can remove this IF statement because get_where_args already handles the ids?
    if k == "id" then
      v = cassandra.uuid(v)
    end
    table.insert(cmd_entity_values, v)
  end

  return self._client:query(cmd, cmd_entity_values)
end

-- Insert or update an entity
-- @param table entity Entity to insert or replace
-- @param table where_keys Selector for the row to insert or update
-- @return table Inserted/updated entity with its rowid property
-- @return table Error if error
function BaseDao:insert_or_update(entity, where_keys)
  return self:insert(entity) -- In Cassandra inserts are upserts
end

-- Find one row according to a condition determined by the keys
-- @param table where_keys Keys used to build a WHERE condition
-- @return table Retrieved row or nil
-- @return table Error if error
function BaseDao:find_one(where_keys)
  local data, total, err = self:find(where_keys, 1, 1)

  local result = nil
  if total > 0 then
    result = data[1]
  end
  return result, err
end

-- Find rows according to a WHERE condition determined by the passed keys
-- @param table (optional) where_keys Keys used to build a WHERE condition
-- @param number page Page to retrieve (default: 1)
-- @param number size Size of the page (default = 30, max = 100)
-- @return table Retrieved rows or empty list
-- @return number Total count of entities matching the SELECT
-- @return table Error if error
function BaseDao:find(where_keys, page, size)
  -- where_keys is optional
  if type(where_keys) ~= "table" then
    size = page
    page = where_keys
    where_keys = nil
  end

  where_keys = dao_utils.serialize(self._schema, where_keys)

  -- Pagination
  -- if not page then page = 1 end
  -- if not size then size = 30 end
  -- size = math.min(size, 100)
  -- local start_offset = ((page - 1) * size)

  -- Prepare the command
  local cmd_fields, cmd_field_values = BaseDao._get_where_args(where_keys)
  local cmd = "SELECT * FROM " .. self._collection
  local cmd_count = "SELECT COUNT(*) FROM " .. self._collection
  if cmd_fields then
    cmd = cmd .. " WHERE " .. cmd_fields .. " ALLOW FILTERING"
    cmd_count = cmd_count .. " WHERE " .. cmd_fields .. " ALLOW FILTERING"
  end

  -- Execute the command
  local results, err = self._client:query(cmd, cmd_field_values)
  if err then
    return nil, nil, err
  end

  -- Count the results too
  local count, err = self._client:query(cmd_count, cmd_field_values)
  if count == nil then
    return nil, nil, err
  end

  local count_value = table.remove(count, 1).count

  -- Deserialization
  for _,result in ipairs(results) do
    result = dao_utils.deserialize(self._schema, result)
    for k,_ in pairs(result) do -- Remove unexisting fields
      if not self._schema[k] then
        result[k] = nil
      end
    end
  end

  return results, count_value
end

-- Delete row(s) according to a WHERE condition determined by the passed keys
-- @param table where_keys Keys used to build a WHERE condition
-- @return number Number of rows affected by the executed query
-- @return table Error if error
function BaseDao:delete_by_id(id)
  local cmd = "DELETE FROM " .. self._collection .. " WHERE id = ?"

  -- Execute the command
  local results, err = self._client:query(cmd, { cassandra.uuid(id) })
  if not results then
    return nil, err
  end

  return 1
end

function BaseDao:query(cmd, args)
  return self._client:query(cmd, args)
end

return BaseDao