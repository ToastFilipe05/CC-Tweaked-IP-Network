-- router.lua Version 1.2
-- Wired IP router with active host discovery, persistent routing table, standardized IP file
-- HELLO_REQUEST/HELLO_REPLY system, auto-save routing table, 60-second intervals

-- ==========================
-- CONFIGURATION
-- ==========================
local sides = {"left","right","top","bottom","front","back"}
local DEFAULT_TTL = 8
local HELLO_INTERVAL = 60
local CLI_PASSWORD = "Admin"
local ROUTING_FILE = "routing_table.txt"
local IP_FILE = "ip.txt"

-- ==========================
-- STATE
-- ==========================
local interfaces = {}
local hosts = {}
local routingTable = {}
local keywords = {}
local lastSeen = {}
local seen = {}
local defaultRoute = nil
local routerIP

-- ==========================
-- UTILITIES
-- ==========================
local function makeUID()
    return tostring(os.clock()) .. "-" .. tostring(math.random(1,99999))
end

local function splitIP(ip)
    if type(ip) ~= "string" then return nil, nil, nil end
    local a,b,c = ip:match("^(%d+)%.(%d+)%.(%d+)")
    return tonumber(a), tonumber(b), tonumber(c)
end

local function matchSubnet(ip, subnet)
    if not ip or not subnet then return false end
    local a1,b1,c1 = splitIP(ip)
    local a2,b2,c2 = splitIP(subnet)
    if not a1 or not a2 then return false end
    return a1==a2 and b1==b2 and c1==c2
end

local function saveRoutingTable()
    local ok, f = pcall(fs.open, ROUTING_FILE, "w")
    if not ok or not f then
        print("Warning: Could not open "..ROUTING_FILE.." for writing.")
        return
    end
    for subnet, side in pairs(routingTable) do
        f.writeLine(subnet .. " " .. side)
    end
    f.close()
end

local function loadRoutingTable()
    if not fs.exists(ROUTING_FILE) then return end
    local f = fs.open(ROUTING_FILE, "r")
    if not f then return end
    while true do
        local line = f.readLine()
        if not line then break end
        local subnet, side = line:match("^(%S+)%s+(%S+)$")
        if subnet and side then
            routingTable[subnet] = side
        end
    end
    f.close()
end

-- ==========================
-- LOAD OR CREATE IP
-- ==========================
if not fs.exists(IP_FILE) then
    routerIP = "10.10.10." .. tostring(os.getComputerID())
    local f = fs.open(IP_FILE, "w")
    f.writeLine(routerIP)
    f.close()
    print("Created " .. IP_FILE .. " with default IP: " .. routerIP)
else
    local f = fs.open(IP_FILE, "r")
    routerIP = f.readLine()
    f.close()
    print("Loaded router IP from " .. IP_FILE .. ": " .. tostring(routerIP))
end

local function updateIPFile()
    local f = fs.open(IP_FILE, "w")
    f.writeLine(routerIP)
    f.close()
end

-- ==========================
-- SETUP INTERFACES
-- ==========================
for _, side in ipairs(sides) do
    if peripheral.getType(side) == "modem" then
        local m = peripheral.wrap(side)
        interfaces[side] = m
        -- open channel 1 for messages
        pcall(m.open, 1)
        print("Opened modem on side " .. side)
    end
end
if next(interfaces) == nil then error("No modems found!") end

-- load any persisted routes
loadRoutingTable()

-- defensive: initialize lastSeen for any route entries (if we have a host listing it)
for host, _ in pairs(hosts) do
    lastSeen[host] = os.clock()
end

-- ==========================
-- PACKET FORWARDING
-- ==========================
local function forwardPacket(packet, incomingSide)
    if type(packet) ~= "table" or not packet.uid then return end
    if seen[packet.uid] then return end
    seen[packet.uid] = true

    packet.ttl = (packet.ttl or DEFAULT_TTL) - 1
    if packet.ttl <= 0 then return end

    if type(packet.payload) == "table" then
        local payload = packet.payload

        -- HELLO_REPLY (from hosts)
        if payload.type == "HELLO_REPLY" then
            -- register host and note when we last saw it
            hosts[packet.src] = incomingSide
            lastSeen[packet.src] = os.clock()
            local subnet = tostring(packet.src):match("^(%d+%.%d+%.%d+)")
            if subnet then routingTable[subnet] = incomingSide end
            if payload.keyword then keywords[payload.keyword] = packet.src end
            print("Discovered host " .. packet.src .. " via " .. incomingSide)
            saveRoutingTable()
            return
        end

        -- HELLO_REQUEST (reply to other routers)
        if payload.type == "HELLO_REQUEST" then
            local reply = {
                uid = makeUID(),
                src = routerIP,
                dst = packet.src,
                ttl = DEFAULT_TTL,
                payload = { type = "HELLO_REPLY" }
            }
            -- reply back on the same side the request arrived
            if interfaces[incomingSide] then
                interfaces[incomingSide].transmit(1, 1, reply)
                print("Replied to HELLO_REQUEST from " .. packet.src .. " on side " .. incomingSide)
            end
            return
        end

        -- PING handling
        if payload.type == "PING" then
            local reply = { uid = makeUID(), src = routerIP, dst = packet.src, ttl = DEFAULT_TTL,
                            payload = { type = "PING_REPLY", message = "pong" } }
            if interfaces[incomingSide] then interfaces[incomingSide].transmit(1, 1, reply) end
            print("Replied to PING from " .. packet.src)
            return
        end
    end

    -- Packet for router itself
    if packet.dst == routerIP then
        print(("Packet for router: %s"):format(textutils.serialize(packet.payload)))
        return
    end

    -- Forwarding: known host
    local targetSide = hosts[packet.dst]
    if targetSide and targetSide ~= incomingSide and interfaces[targetSide] then
        interfaces[targetSide].transmit(1, 1, packet)
        return
    end

    -- Forwarding: routing table (by subnet)
    for subnet, side in pairs(routingTable) do
        if matchSubnet(packet.dst, subnet) and side ~= incomingSide and interfaces[side] then
            interfaces[side].transmit(1, 1, packet)
            return
        end
    end

    -- Default route
    if defaultRoute and interfaces[defaultRoute] and defaultRoute ~= incomingSide then
        interfaces[defaultRoute].transmit(1, 1, packet)
        return
    end

    print("Dropping packet to " .. tostring(packet.dst) .. " (no route)")
end

-- ==========================
-- PERIODIC HELLO + TIMEOUT
-- ==========================
local function broadcastHelloRequest()
    local packet = { uid = makeUID(), src = routerIP, dst = "0", ttl = DEFAULT_TTL, payload = { type = "HELLO_REQUEST" } }
    for side, modem in pairs(interfaces) do
        pcall(modem.transmit, 1, 1, packet)
    end
    print("Broadcasted HELLO_REQUEST to all interfaces.")
end

local function periodicHelloCheck()
    while true do
        broadcastHelloRequest()

        -- allow some time for replies to arrive before checking (small sleep)
        -- but keep the main sleep at HELLO_INTERVAL
        local startTime = os.clock()
        -- wait up to 1 second to give replies a moment before timeout check
        while os.clock() - startTime < 1 do os.pullEvent("timer") end

        local now = os.clock()
        for host, t in pairs(lastSeen) do
            if now - t > HELLO_INTERVAL then
                print("Host timed out: " .. host)
                hosts[host] = nil
                lastSeen[host] = nil
                local subnet = tostring(host):match("^(%d+%.%d+%.%d+)")
                if subnet then routingTable[subnet] = nil end
                for k, v in pairs(keywords) do if v == host then keywords[k] = nil end end
                saveRoutingTable()
            end
        end

        os.sleep(HELLO_INTERVAL)
    end
end

-- ==========================
-- CLI
-- ==========================
local function printHelp()
    print([[Router Commands:
  show routes
  show hosts
  show keywords
  set ip <ip>
  add route <subnet> <side>
  del route <subnet>
  set defaultroute <side>
  sides
  exit
  help]])
end

local function cli()
    io.write("Enter router CLI password: ")
    local input = read("*")
    if input ~= CLI_PASSWORD then print("Incorrect password!") return end
    print("Access granted. Router CLI started.")
    while true do
        io.write("(router)> ")
        local line = read()
        if not line then break end
        local cmd, arg1, arg2, arg3 = line:match("^(%S+)%s*(%S*)%s*(%S*)%s*(%S*)$")
        if cmd == "help" then printHelp()
        elseif cmd == "exit" then return
        elseif cmd == "show" then
            if arg1 == "routes" then for s, t in pairs(routingTable) do print(s .. " -> " .. t) end
            elseif arg1 == "hosts" then for h, s in pairs(hosts) do print(h .. " -> " .. s) end
            elseif arg1 == "keywords" then for k, v in pairs(keywords) do print(k .. " -> " .. v) end
            else print("Usage: show routes | show hosts | show keywords") end
        elseif cmd == "set" and arg1 == "ip" and arg2 ~= "" then
            routerIP = arg2
            updateIPFile()
            print("Router IP updated to " .. routerIP)
        elseif cmd == "add" and arg1 == "route" and arg2 ~= "" and arg3 ~= "" then
            local subnet, side = arg2, arg3
            if not interfaces[side] then print("Invalid side: " .. side)
            else routingTable[subnet] = side; print("Added route " .. subnet .. " -> " .. side); saveRoutingTable() end
        elseif cmd == "del" and arg1 == "route" and arg2 ~= "" then
            routingTable[arg2] = nil; print("Deleted route for " .. arg2); saveRoutingTable()
        elseif cmd == "set" and arg1 == "defaultroute" and arg2 ~= "" then
            if interfaces[arg2] then defaultRoute = arg2; print("Default route set to " .. arg2)
            else print("Invalid side: " .. arg2) end
        elseif cmd == "sides" then for s, _ in pairs(interfaces) do print("  " .. s) end
        else print("Unknown command.") end
    end
end

-- ==========================
-- EVENT LOOP
-- ==========================
local function listener()
    while true do
        local e, side, ch, reply, msg, dist = os.pullEvent("modem_message")
        if interfaces[side] and type(msg) == "table" and msg.uid then
            forwardPacket(msg, side)
        end
    end
end

-- ==========================
-- STARTUP
-- ==========================
-- Send an immediate discovery ping once at startup (helps catch devices before first interval)
broadcastHelloRequest()
parallel.waitForAny(listener, cli, periodicHelloCheck)
