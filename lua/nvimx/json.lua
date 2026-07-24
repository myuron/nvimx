-- 決定的 JSON エンコーダ (キーをソートし 2-space indent で pretty-print)。
-- lock 成果物 (plugins.json) は git にコミットされる唯一の真実なので、
-- vim.json.encode のテーブル走査順に依存しない安定した出力が必要。
local M = {}

-- 空テーブルの array / object 判別のためのマーカー
function M.array(t)
  return setmetatable(t or {}, { __jsontype = "array" })
end

function M.object(t)
  return setmetatable(t or {}, { __jsontype = "object" })
end

local function is_array(t)
  local mt = getmetatable(t)
  if mt and mt.__jsontype then
    return mt.__jsontype == "array"
  end
  return vim.islist(t) and #t > 0
end

local function encode(v, indent)
  if v == nil or v == vim.NIL then
    return "null"
  end
  local ty = type(v)
  if ty == "string" or ty == "number" or ty == "boolean" then
    return vim.json.encode(v)
  end
  if ty ~= "table" then
    error("cannot encode value of type " .. ty)
  end

  local child_indent = indent .. "  "
  if is_array(v) then
    if #v == 0 then
      return "[]"
    end
    local items = {}
    for _, item in ipairs(v) do
      items[#items + 1] = child_indent .. encode(item, child_indent)
    end
    return "[\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "]"
  end

  local keys = {}
  for k in pairs(v) do
    assert(type(k) == "string", "object keys must be strings")
    keys[#keys + 1] = k
  end
  if #keys == 0 then
    return "{}"
  end
  table.sort(keys)
  local items = {}
  for _, k in ipairs(keys) do
    items[#items + 1] = ("%s%s: %s"):format(child_indent, vim.json.encode(k), encode(v[k], child_indent))
  end
  return "{\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "}"
end

---@param v any
---@return string
function M.encode(v)
  return encode(v, "") .. "\n"
end

return M
