--====================================================
-- switch.lua | Version 1.2
--====================================================
-- Purpose:
--   Forwards packets between directly connected hosts and switches.
--   Learns hosts behind neighbor switches automatically.
--   Maintains a routing_table.txt of learned connections.
--====================================================

local version = "1.2"
local routing_table_file = "routing_table.txt"
local routing_table = {}
local default_route = nil
local interfaces = {}

--====================================================
-- Helper Functions
--====================================================

local function log(msg)
    print("[SWITCH] " .. msg)
end

local function loadRoutingTable()
    routing_table = {}
    if fs.exists(routing_table_file) then
        local f = fs.open(routing_table_file, "r")
        if f then
            local data = textutils.unserialize(f.readAll())
            f.close()
            if type(data) == "table" then
                routing_table = data
                log("Loaded routing table (" .. tostring(#(routing_table)) .. " entries).")
            else
                log("Invalid routing table, recreating.")
            end
        end
    else
        log("No routing table found, creating new.")
    end
end

local function saveRoutingTable()
    local f = fs.open(routing_table_file, "w")
    if f then
        f.write(textutils.serialize(routing_table))
        f.close()
    end
end

local function discoverModems()
    for _, side in ipairs(rs.getSides()) do
        if peripheral.getType(side) == "modem" then
            local modem = peripheral.wrap(side)
            modem.open(1)
            interfaces[side] = modem
            log("Modem detected on side: " .. side)
        end
    end
end

local function promptDefaultRoute()
    log("Enter the side for the default route (e.g., back, left, right, top, bottom, front):")
    default_route = read()
    if not interfaces[default_route] then
        log("Invalid side. Using 'back' as fallback default route.")
        default_route = "back"
    end
    log("Default route set to " .. default_route)
end

--====================================================
-- Packet Handling
--====================================================

local function forwardPacket(side, packet)
    local dest = packet.dst
    local src = packet.src

    -- Learn source host location (passive host propagation)
    if src and dest ~= "0" and not routing_table[src] then
        routing_table[src] = side
        log("Learned route: " .. src .. " -> " .. side)
        saveRoutingTable()
    end

    if dest == "0" then
        -- Broadcast: send out all interfaces except incoming
        for s, modem in pairs(interfaces) do
            if s ~= side then
                modem.transmit(1, 1, packet)
            end
        end
        log("Broadcast packet " .. tostring(src) .. " -> " .. tostring(dest) .. " forwarded to all sides except " .. side)
    else
        -- Unicast: normal forwarding
        local out_side = routing_table[dest] or default_route
        if out_side and interfaces[out_side] then
            if out_side == side then
                log("Destination " .. dest .. " is on incoming side, dropping packet.")
                return
            end
            interfaces[out_side].transmit(1, 1, packet)
            log("Forwarded packet " .. tostring(src) .. " -> " .. tostring(dest) .. " via " .. out_side)
        else
            log("No route found for " .. tostring(dest) .. ", dropping packet.")
        end
    end
end



--====================================================
-- Main Loop
--====================================================

local function main()
    log("Switch v" .. version .. " booting up...")
    loadRoutingTable()
    discoverModems()
    promptDefaultRoute()
    log("Listening for packets...")

    while true do
        local event, side, channel, replyChannel, message, distance = os.pullEvent("modem_message")

        if type(message) == "table" and message.dst and message.src then
            forwardPacket(side, message)
        end
    end
end

--====================================================
-- Run
--====================================================
main()
