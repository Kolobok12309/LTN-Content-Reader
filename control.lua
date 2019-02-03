
-- localize often used functions and strings
local match = string.match
local match_string = "([^,]+),([^,]+)"
local btest = bit32.btest
local signal_networkID = {type="virtual", name="ltn-network-id"}
local provider_reader = "ltn-provider-reader"
local requester_reader = "ltn-requester-reader"


-- LTN interface event functions
function OnStopsUpdated(event)
  if event.data then
    --log("Stop Data:"..serpent.block(event.data) )
    global.stop_network_ID = {}

    -- build stop netwok_ID lookup table
    for stopID, stop in pairs(event.data) do
      if stop then
        global.stop_network_ID[stopID] = stop.network_id
      end
    end
  end
end

function OnDispatcherUpdated(event)
  -- ltn provides data per stop, aggregate over network and item
  global.ltn_provided = {}
  global.ltn_requested = {}

  if not event.data then
    return
  end

  -- data.Provided = { [item], { [stopID], count } }
  for item, stops in pairs(event.data.Provided) do
    for stopID, count in pairs(stops) do
      local networkID = global.stop_network_ID[stopID]
      if networkID then
        global.ltn_provided[networkID] = global.ltn_provided[networkID] or {}
        global.ltn_provided[networkID][item] = (global.ltn_provided[networkID][item] or 0) + count
      end
    end
  end

  -- data.Requests = { stopID, item, count }
  for _, request in pairs(event.data.Requests) do
    local networkID = global.stop_network_ID[request.stopID]
    if networkID then
      global.ltn_requested[networkID] = global.ltn_requested[networkID] or {}
      global.ltn_requested[networkID][request.item] = (global.ltn_requested[networkID][request.item] or 0) - request.count
    end
  end

  -- synchronize combinator update interval with LTN
  -- log("Updating UpdateInterval: "..tostring(global.update_interval).." << "..tostring(event.data.UpdateInterval) )
  global.update_interval = event.data.UpdateInterval
end

-- spread out updating combinators
function OnTick(event)
  -- global.update_interval LTN update interval are synchronized in OnDispatcherUpdated
  local offset = event.tick % global.update_interval
  local cc_count = #global.content_combinators
  for i=cc_count - offset, 1, -1 * global.update_interval do
    -- log( "("..tostring(event.tick)..") on_tick updating "..i.."/"..cc_count )
    local combinator = global.content_combinators[i]
    if combinator.valid then
      Update_Combinator(combinator)
    else
      table.remove(global.content_combinators, i)
      if #global.content_combinators == 0 then
        script.on_event(defines.events.on_tick, nil)
      end
    end
  end
end

function Update_Combinator(combinator)
  -- get network id from combinator parameters
  local first_signal = combinator.get_control_behavior().get_signal(1)
  local max_signals = combinator.get_control_behavior().signals_count
  local selected_networkID = -1

  if first_signal and first_signal.signal and first_signal.signal.name == "ltn-network-id" then
    selected_networkID = first_signal.count
  else
    log("Error: combinator must have ltn-network-id set at index 1. Setting network id to -1 (any).")
  end

  local signals = { { index = 1, signal = signal_networkID, count = selected_networkID } }
  local index = 2

  -- for many signals performance is better to aggregate first instead of letting factorio do it
  local items = {}

  if combinator.name == provider_reader then
    for networkID, item_data in pairs(global.ltn_provided) do
      if btest(selected_networkID, networkID) then
        for item, count in pairs(item_data) do
          items[item] = (items[item] or 0) + count
        end
      end
    end
  end

  if combinator.name == requester_reader then
    for networkID, item_data in pairs(global.ltn_requested) do
      if btest(selected_networkID, networkID) then
        for item, count in pairs(item_data) do
          items[item] = (items[item] or 0) + count
        end
      end
    end
  end

  -- log("DEBUG: Items in network "..selected_networkID..": "..serpent.block(items) )

  -- generate signals from aggregated item list
  for item, count in pairs(items) do
    local itype, iname = match(item, match_string)
    if itype and iname and (game.item_prototypes[iname] or game.fluid_prototypes[iname]) then
      if max_signals >= index then
        if count >  2147483647 then count =  2147483647 end
        if count < -2147483648 then count = -2147483648 end
        signals[#signals+1] = {index = index, signal = {type=itype, name=iname}, count = count}
        index = index+1
      else
        log("[LTN Content Reader] Error: signals in network "..selected_networkID.." exceed "..max_signals.." combinator signal slots. Not all signals will be displayed.")
        break
      end
    end
  end
  -- log("DEBUG: signals = "..serpent.block(signals) )
  combinator.get_control_behavior().parameters = { parameters = signals }

end


-- add/remove event handlers
function OnEntityCreated(event)
  local entity = event.created_entity
  if entity.name == provider_reader or entity.name == requester_reader then
    -- if not set use default network id -1 (any network)
    local first_signal = entity.get_control_behavior().get_signal(1)
    if not (first_signal and first_signal.signal and first_signal.signal.name == "ltn-network-id") then
      entity.get_or_create_control_behavior().parameters = { parameters = { { index = 1, signal = signal_networkID, count = -1 } } }
    end

    table.insert(global.content_combinators, entity)

    if #global.content_combinators == 1 then
      script.on_event(defines.events.on_tick, OnTick)
    end
  end
end

function OnEntityRemoved(event)
  local entity = event.entity
  if entity.name == provider_reader or entity.name == requester_reader then
    for i=#global.content_combinators, 1, -1 do
      if global.content_combinators[i].unit_number == entity.unit_number then
        table.remove(global.content_combinators, i)
      end
    end

    if #global.content_combinators == 0 then
			script.on_event(defines.events.on_tick, nil)
    end
  end
end

---- Initialisation  ----
do
local function init_globals()
  global.stop_network_ID = global.stop_network_ID or {}
  global.ltn_contents = nil
  global.ltn_provided = global.ltn_provided or {}
  global.ltn_requested = global.ltn_requested or {}
  global.content_combinators = global.content_combinators or {}
  global.update_interval = global.update_interval or 60

  -- remove unused globals froms save
  global.last_update_tick = nil
end

local function register_events()
  -- register events from LTN
  if remote.interfaces["logistic-train-network"] then
    script.on_event(remote.call("logistic-train-network", "get_on_stops_updated_event"), OnStopsUpdated)
    script.on_event(remote.call("logistic-train-network", "get_on_dispatcher_updated_event"), OnDispatcherUpdated)
  end

  -- register game events
  script.on_event({defines.events.on_built_entity, defines.events.on_robot_built_entity}, OnEntityCreated)
  script.on_event({defines.events.on_pre_player_mined_item, defines.events.on_robot_pre_mined, defines.events.on_entity_died}, OnEntityRemoved)
  if #global.content_combinators > 0 then
    script.on_event(defines.events.on_tick, OnTick)
  end
end


script.on_init(function()
  init_globals()
  register_events()
end)

script.on_configuration_changed(function(data)
  init_globals()
  register_events()
end)

script.on_load(function(data)
  register_events()
end)
end