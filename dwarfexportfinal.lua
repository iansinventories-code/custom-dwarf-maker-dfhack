-- dwarfmaker-export-v7-full.lua
-- Robust DFHack exporter for Custom Dwarf Maker (appearance + RP + description)
-- Goals:
--  * Never crash on missing struct fields (pcall wrappers)
--  * Export:
--      - physical_description (DF "Description" text)  [BEST signal for skin/hair/eyes + length words]
--      - appearance (v4-style): tissue objects + df_color_names
--      - appearance_v3 (raw arrays): colors + tissue_style_type + tissue_length + tissue_style_id + tissue_style
--      - traits / values / preferences (lightweight but useful)

local json = require('json')

local _PHYS_DESC_SOURCE = nil

local function prettify_enum_name(s)
  if s == nil then return nil end
  s = tostring(s)

  -- turn snake_case / kebab-case into spaces first
  s = s:gsub("[_%-%./]+", " ")

  -- split camelCase / PascalCase / acronym boundaries
  s = s:gsub("(%l)(%u)", "%1 %2")
  s = s:gsub("(%u)(%u%l)", "%1 %2")

  -- small cleanup / special cases
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  s = s:gsub("%s+", " ")

  -- DF enum names sometimes come through as single lowercase runs.
  -- Add a few targeted fixes for common need names.
  local fixes = {
    acquireobject = "acquire object",
    drinkalcohol = "drink alcohol",
    becreative = "be creative",
    stayoccupied = "stay occupied",
    martialtraining = "martial training",
    selfexamination = "self examination",
    family = "family",
    socialize = "socialize",
    learn = "learn",
    prayormeditate = "pray or meditate",
  }
  local lower = s:lower()
  if fixes[lower] then s = fixes[lower] end

  return s
end


local function safe_get(obj, key)
  if obj == nil then return nil end
  local ok, val = pcall(function() return obj[key] end)
  if ok then return val end
  return nil
end

local function safe_tostring(x)
  if x == nil then return nil end
  local ok, s = pcall(tostring, x)
  if ok then return s end
  return nil
end

local function get_selected_unit()
  local u = dfhack.gui.getSelectedUnit(true)
  if u then return u end
  return dfhack.gui.getSelectedUnit()
end

local function find_unit_by_id(uid)
  if not uid then return nil end
  for _,u in ipairs(df.global.world.units.all) do
    if u.id == uid then return u end
  end
  return nil
end

local function translate_name(lang_name)
  if not lang_name then return nil end

  -- DFHack builds differ: TranslateName may not exist.
  if dfhack.TranslateName then
    local ok, s = pcall(dfhack.TranslateName, lang_name, true)
    if ok and s and #s > 0 then return s end
  end

  -- Newer DFHack exposes translation helpers here.
  if dfhack.translation and dfhack.translation.translateName then
    local ok, s = pcall(dfhack.translation.translateName, lang_name, true)
    if ok and s and #s > 0 then return s end
  end

  -- Fallback: best-effort stitch from name fields.
  -- lang_name is typically a df.language_name object.
  local first = safe_tostring(lang_name.first_name)
  local nick  = safe_tostring(lang_name.nickname)
  local last  = safe_tostring(lang_name.last_name)

  if first and #first > 0 and last and #last > 0 then
    if nick and #nick > 0 then
      return string.format('%s "%s" %s', first, nick, last)
    else
      return string.format('%s %s', first, last)
    end
  end

  return safe_tostring(lang_name)
end

local function get_age_years(unit)
  local ok, v = pcall(dfhack.units.getAge, unit)
  if ok and v then return math.floor(v + 0.0001) end
  local cur_year = df.global.cur_year or 0
  local rel = safe_get(unit, 'relations')
  local by = rel and safe_get(rel, 'birth_year') or 0
  if cur_year > 0 and by > 0 then return cur_year - by end
  return nil
end

local function get_profession(unit)
  local ok, p = pcall(dfhack.units.getProfessionName, unit)
  if ok and p then return p end
  return nil
end

local function get_physical_description(unit)
  _PHYS_DESC_SOURCE = nil
  if dfhack.units then
    if dfhack.units.getPhysicalDescription then
      local ok, s = pcall(dfhack.units.getPhysicalDescription, unit)
      if ok and s and #tostring(s) > 0 then _PHYS_DESC_SOURCE = "dfhack.units.getPhysicalDescription"; return tostring(s) end
    end
    if dfhack.units.get_description then
      local ok, s = pcall(dfhack.units.get_description, unit)
      if ok and s and #tostring(s) > 0 then _PHYS_DESC_SOURCE = "dfhack.units.get_description"; return tostring(s) end
    end
    if dfhack.units.getDescription then
      local ok, s = pcall(dfhack.units.getDescription, unit)
      if ok and s and #tostring(s) > 0 then _PHYS_DESC_SOURCE = "dfhack.units.getDescription"; return tostring(s) end
    end
  end
  return nil
end

local function get_appearance_struct(unit)
  return safe_get(unit, 'appearance') or safe_get(unit, 'I_appearance')
end

local function get_descriptor_color_name_by_index(idx)
  local world = df.global.world
  if not world then return nil end
  local raws = safe_get(world, 'raws')
  if not raws then return nil end

  local desc = safe_get(raws, 'descriptors')
  local colors = desc and (safe_get(desc, 'colors') or safe_get(desc, 'color')) or nil
  if not colors then
    colors = safe_get(raws, 'descriptor_colors')
  end
  if not colors then return nil end

  if idx < 0 or idx >= #colors then return nil end
  local c = colors[idx]
  if not c then return nil end
  return safe_tostring(safe_get(c,'name')) or safe_tostring(safe_get(c,'id')) or nil
end

local function extract_colors(unit)
  local out = { raw = {}, names = {}, named = {} }
  local app = get_appearance_struct(unit)
  if not app then return out end
  local cols = safe_get(app, 'colors')
  if not cols then return out end

  for i=0,#cols-1 do
    local idx = cols[i]
    table.insert(out.raw, idx)
    local nm = get_descriptor_color_name_by_index(idx)
    table.insert(out.names, nm or tostring(idx))
    out.named[tostring(i)] = nm or tostring(idx)  -- numeric slots (exporter-v3 compatibility)
  end

  return out
end

local function extract_tissue_v4(unit)
  local app = get_appearance_struct(unit)
  if not app then return {} end

  local types = safe_get(app, 'tissue_style_type_id') or safe_get(app, 'tissue_style_type')
  local lens  = safe_get(app, 'tissue_length')
  local sids  = safe_get(app, 'tissue_style_id')
  local style = safe_get(app, 'tissue_style') -- sometimes present

  if not types or not lens or not sids then return {} end

  local n = math.min(#types, #lens, #sids)
  local arr = {}
  for i=0,n-1 do
    local t = tonumber(types[i]) or -1
    local l = tonumber(lens[i]) or -30000
    local sid = tonumber(sids[i]) or -1
    local st = style and (tonumber(style[i]) or nil) or nil
    table.insert(arr, { idx=i, type_id=t, length=l, style_id=sid, style=st })
  end
  return arr
end

local function extract_tissue_v3_raw(unit)
  local app = get_appearance_struct(unit)
  if not app then return nil end

  local types = safe_get(app, 'tissue_style_type_id') or safe_get(app, 'tissue_style_type')
  local lens  = safe_get(app, 'tissue_length')
  local sids  = safe_get(app, 'tissue_style_id')
  local style = safe_get(app, 'tissue_style')

  if not types or not lens or not sids then return nil end

  local out = { tissue_style_type={}, tissue_length={}, tissue_style_id={}, tissue_style={} }
  local n = math.min(#types, #lens, #sids)
  for i=0,n-1 do
    out.tissue_style_type[i+1] = tonumber(types[i]) or -1
    out.tissue_length[i+1] = tonumber(lens[i]) or -30000
    out.tissue_style_id[i+1] = tonumber(sids[i]) or -1
    out.tissue_style[i+1] = style and (tonumber(style[i]) or -1) or -1
  end
  return out
end

local function parse_desc_colors(desc)
  if not desc then return {} end
  local d = string.lower(desc)

  local out = {}
  -- "His skin is cinnamon." OR "His dark tan skin is ..."
  local a = string.match(d, "his ([%a%s]+) skin is")
  local b = string.match(d, "his skin is ([%a%s]+)%.")
  if a and #a>0 then out.skin = a:gsub("^%s+",""):gsub("%s+$","") end
  if (not out.skin) and b and #b>0 then out.skin = b:gsub("^%s+",""):gsub("%s+$","") end

  local h = string.match(d, "his hair is ([%a%s]+)%.")
  if h and #h>0 then out.hair = h:gsub("^%s+",""):gsub("%s+$","") end

  -- eyes tend to be "His ____ eyes are ..." or "His ____ eyes"
  local e = string.match(d, "his ([%a%s]+) eyes are")
  if e and #e>0 then out.eyes = e:gsub("^%s+",""):gsub("%s+$","") end

  return out
end

-- Lightweight trait export (0..100-ish)
local function export_traits(unit)
  local out = {}
  local p = safe_get(unit, 'status')
  p = p and safe_get(p, 'current_soul')
  if not p then return out end
  local pers = safe_get(p, 'personality')
  if not pers then return out end
  local traits = safe_get(pers, 'traits')
  if not traits then return out end
  -- traits is an array indexed by df.personality_facet_type
  for i=0,#traits-1 do
    out[tostring(i)] = tonumber(traits[i]) or 0
  end
  return out
end

local function export_values(unit)
  local out = {}
  local soul = safe_get(unit,'status')
  soul = soul and safe_get(soul,'current_soul')
  if not soul then return out end
  local pers = safe_get(soul,'personality')
  if not pers then return out end
  local vals = safe_get(pers,'values')
  if not vals then return out end
  for i=0,#vals-1 do
    local v = vals[i]
    local t = v and safe_get(v,'type') or nil
    local s = v and safe_get(v,'strength') or nil
    out[tostring(i)] = { type = t and tonumber(t) or -1, strength = s and tonumber(s) or 0 }
  end
  return out
end

local function export_preferences(unit)
  local out = {}
  local soul = safe_get(unit,'status')
  soul = soul and safe_get(soul,'current_soul')
  if not soul then return out end
  local prefs = safe_get(soul,'preferences')
  if not prefs then return out end
  -- preferences is a vector of df.unit_preference
  for i=0,#prefs-1 do
    local p = prefs[i]
    if p then
      out[#out+1] = {
        type = safe_tostring(safe_get(p,'type')),
        item_type = tonumber(safe_get(p,'item_type') or -1),
        creature_id = tonumber(safe_get(p,'creature_id') or -1),
        color_id = tonumber(safe_get(p,'color_id') or -1),
        material = tonumber(safe_get(p,'mat_type') or -1),
        mat_index = tonumber(safe_get(p,'mat_index') or -1),
      }
    end
  end
  return out
end


local function enum_name(enum_tbl, idx)
  if not enum_tbl or idx == nil then return nil end
  local ok, v = pcall(function() return enum_tbl[idx] end)
  if ok and v then return tostring(v) end
  return nil
end

-- Export "needs" (e.g., pray, socialize, drink, learn, be with family)
-- Highly version-dependent, but many DFHack builds expose pers.needs as a vector.
local function export_needs(unit)
  local out = {}
  local soul = safe_get(unit,'status')
  soul = soul and safe_get(soul,'current_soul')
  if not soul then return out end
  local pers = safe_get(soul,'personality')
  if not pers then return out end

  local needs = safe_get(pers,'needs')
  if not needs then return out end

  for i=0,#needs-1 do
    local n = needs[i]
    if n then
      local id = safe_get(n,'id')
      local lvl = safe_get(n,'level')
      local foc = safe_get(n,'focus')
      local name = nil
      local pretty_name = nil
      if id ~= nil and df and df.need_type then
        name = enum_name(df.need_type, tonumber(id))
        pretty_name = prettify_enum_name(name)
      end
      out[#out+1] = {
        id = id and tonumber(id) or -1,
        name = name,
        pretty_name = pretty_name,
        level = lvl and tonumber(lvl) or 0,
        focus = foc and tonumber(foc) or 0,
      }
    end
  end
  return out
end

-- Export mental attributes (willpower, intuition, memory, etc.)
local function export_mental_attrs(unit)
  local out = {}
  local soul = safe_get(unit,'status')
  soul = soul and safe_get(soul,'current_soul')
  if not soul then return out end

  local ma = safe_get(soul,'mental_attrs')
  if not ma then return out end

  for i=0,#ma-1 do
    local a = ma[i]
    if a then
      local name = nil
      if df and df.mental_attribute_type then name = enum_name(df.mental_attribute_type, i) end
      out[#out+1] = {
        id = i,
        name = name,
        value = tonumber(safe_get(a,'value') or 0),
        max_value = tonumber(safe_get(a,'max_value') or 0),
      }
    end
  end
  return out
end

-- Export basic stress + emotions/thoughts (optional; may be missing on some builds)
local function export_mood(unit)
  local out = {}
  local soul = safe_get(unit,'status')
  soul = soul and safe_get(soul,'current_soul')
  if not soul then return out end
  local pers = safe_get(soul,'personality')
  if not pers then return out end

  -- stress is often a single integer
  local st = safe_get(pers,'stress')
  if st ~= nil then out.stress = tonumber(st) end

  -- emotions is often a vector (df.unit_emotion)
  local emos = safe_get(pers,'emotions')
  if emos then
    out.emotions = {}
    for i=0,#emos-1 do
      local e = emos[i]
      if e then
        local et = safe_get(e,'type')
        local ename = nil
        local pretty_name = nil
        if et ~= nil and df and df.emotion_type then
          ename = enum_name(df.emotion_type, tonumber(et))
          pretty_name = prettify_enum_name(ename)
        end
        out.emotions[#out.emotions+1] = {
          type = et and tonumber(et) or -1,
          name = ename,
          pretty_name = pretty_name,
          strength = tonumber(safe_get(e,'strength') or 0),
          thought = tonumber(safe_get(e,'thought') or -1),
          year = tonumber(safe_get(e,'year') or -1),
          year_tick = tonumber(safe_get(e,'year_tick') or -1),
        }
      end
    end
  end

  return out
end

local function main(args)
  local uid = nil
  if args and #args >= 1 then uid = tonumber(args[1]) end
  local unit = uid and find_unit_by_id(uid) or get_selected_unit()
  if not unit then
    qerror("No unit selected. Select a unit in-game, or run: dwarfmaker-export-v7-full <unit_id>")
  end

  local desc = get_physical_description(unit)
  local colors = extract_colors(unit)
  local desc_colors = parse_desc_colors(desc)

  local payload = {
    version = "dwarfmaker-export-v7-full",
    unit_id = unit.id,
    sex = safe_get(unit, 'sex'),
    gender = (safe_get(unit, 'sex') == 0 and "female") or (safe_get(unit, 'sex') == 1 and "male") or "unknown",
    name = translate_name(dfhack.units.getVisibleName(unit)),
    profession = get_profession(unit),
    age = get_age_years(unit),
    physical_description = desc,
    physical_description_source = _PHYS_DESC_SOURCE,

    -- v4-style (used by your HTML importer when available)
    appearance = {
      df_color_indices = colors.raw,
      df_color_names = colors.names,
      colors_named = desc_colors, -- labeled by parsing description (best effort)
      tissue = extract_tissue_v4(unit),
    },

    -- v3 raw arrays (so you can debug mappings)
    appearance_v3 = {
      colors = colors.raw,
      colors_named = colors.named, -- numeric slot names
      note = "tissue_style_type mapping observed: 39=hair,36=beard,37=stache,38=sideburn; use physical_description for skin/hair/eyes words",
    },

    traits = export_traits(unit),
    values = export_values(unit),
    preferences = export_preferences(unit),
    needs = export_needs(unit),
    mental_attrs = export_mental_attrs(unit),
    mood = export_mood(unit),
  }

  -- add v3 tissue arrays if available
  local t3 = extract_tissue_v3_raw(unit)
  if t3 then
    payload.appearance_v3.tissue_style_type = t3.tissue_style_type
    payload.appearance_v3.tissue_length = t3.tissue_length
    payload.appearance_v3.tissue_style_id = t3.tissue_style_id
    payload.appearance_v3.tissue_style = t3.tissue_style
  end

  local outname = string.format("dwarfmaker_unit_%d.json", unit.id)
  local outpath = dfhack.getDFPath() .. "/" .. outname
  local f = io.open(outpath, "w")
  if not f then qerror("Could not write file: " .. outpath) end
  f:write(json.encode(payload))
  f:close()

  print(string.format("DWARFMAKER EXPORT V7 OK -> %s", outpath))
  if not desc then print("NOTE: physical_description was nil (DFHack build may not support getPhysicalDescription); exporter still wrote df_color_names + appearance arrays. If you need exact descriptor words, we can add a UI-scrape fallback.")
  print("NOTE: physical_description is nil in this DFHack build; skin auto-detect will be limited.") end
end

if ... == nil then
  main({})
else
  main({...})
end
