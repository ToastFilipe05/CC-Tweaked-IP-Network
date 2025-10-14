-- router.lua
-- Wired IP router with:
--   - Host learning (client hello packets)
--   - Router-to-router hello ping
--   - Automatic removal of old IP on IP change
--   - Password-protected CLI
--   - Routing table management
--   - Keyword/IP mapping support
--   - Default route support

-- ==========================
-- CONFIGURATION
-- ==========================
local sides = {"left","right","top","bottom","front","back"} -- modem sides
local DEFAULT_TTL = 8
local routerIP = "10.10.10." .. os.getComputerID() -- router's IP (changeable via CLI)
local CLI_PASSWORD = "Admin"

-- ==========================
-- STATE
-- ==========================
local interfaces = {}       -- side -> modem
local hosts = {}            -- host IP -> side
local routingTable = {}     -- subnet -> side
local keywords = {}         -- keyword -> IP
local seen = {}             -- packet UID cache
local defaultRoute = nil    -- optional default route side

-- ==========================
-- UTILITIES
-- ==========================
local function makeUID()
    return tostring(os.clock()).."-"..tostring(math.random(1,99999))
end

local function splitIP(ip)
    local a,b,c = ip:match("(%d+)%.(%d+)%.(%d+)")
    return tonumber(a), tonumber(b), tonumber(c)
end

local function matchSubnet(ip, subnet)
    local a1,b1,c1 = splitIP(ip)
    local a2,b2,c2 = splitIP(subnet)
    return a1==a2 and b1==b2 and c1==c2
end

-- ==========================
-- SETUP INTERFACES
-- ==========================
for _, side in ipairs(sides) do
    if peripheral.getType(side) == "modem" then
        local m = peripheral.wrap(side)
        interfaces[side] = m
        m.open(1)
        print("Opened modem on side "..side)
    end
end
if next(interfaces) == nil then error("No modems found!") end

-- ==========================
-- PACKET FORWARDING
-- ==========================
local function forwardPacket(packet, incomingSide)
    if seen[packet.uid] then return end
    seen[packet.uid] = true

    packet.ttl = (packet.ttl or DEFAULT_TTL) - 1
    if packet.ttl <= 0 then return end

    -- LEARN HOST OR ROUTER
    if packet.src and incomingSide then
        hosts[packet.src] = incomingSide
        local subnet = packet.src:match("^(%d+%.%d+%.%d+)")
        routingTable[subnet] = incomingSide
    end

    -- HANDLE HELLO / PING PACKETS
    if type(packet.payload)=="table" then
        local payload = packet.payload

        if payload.type=="HELLO_CLIENT" then
            print("Learned client "..packet.src.." via "..incomingSide)
            if payload.keyword then
                keywords[payload.keyword] = packet.src
                print("Assigned keyword '"..payload.keyword.."' -> "..packet.src)
            end
            return

        elseif payload.type=="HELLO_ROUTER" then
            hosts[packet.src] = incomingSide
            local subnet = packet.src:match("^(%d+%.%d+%.%d+)")
            routingTable[subnet] = incomingSide
            print("Learned router "..packet.src.." via "..incomingSide)
            if payload.remove then
                hosts[payload.remove] = nil
                local oldSubnet = payload.remove:match("^(%d+%.%d+%.%d+)")
                routingTable[oldSubnet] = nil
                print("Removed old IP: "..payload.remove)
            end
            local reply = { uid=makeUID(), src=routerIP, dst=packet.src, ttl=DEFAULT_TTL,
                            payload={ type="HELLO_ROUTER_REPLY" } }
            interfaces[incomingSide].transmit(1,1,reply)
            return

        elseif payload.type=="HELLO_ROUTER_REPLY" then
            hosts[packet.src] = incomingSide
            local subnet = packet.src:match("^(%d+%.%d+%.%d+)")
            routingTable[subnet] = incomingSide
            print("Received HELLO_ROUTER_REPLY from "..packet.src)
            return

        elseif payload.type=="PING" then
            local reply = { uid=makeUID(), src=routerIP, dst=packet.src, ttl=DEFAULT_TTL,
                            payload={ type="PING_REPLY", message="pong" } }
            interfaces[incomingSide].transmit(1,1,reply)
            print("Replied to PING from "..packet.src)
        end
    end

    -- PACKET FOR ROUTER ITSELF
    if packet.dst == routerIP then
        print(("Packet for router: %s"):format(textutils.serialize(packet.payload)))
        return
    end

    -- FORWARDING
    local targetSide = hosts[packet.dst]
    if targetSide and targetSide ~= incomingSide then
        interfaces[targetSide].transmit(1,1,packet)
        return
    end

    for subnet, side in pairs(routingTable) do
        if matchSubnet(packet.dst, subnet) and side ~= incomingSide then
            interfaces[side].transmit(1,1,packet)
            return
        end
    end

    -- DEFAULT ROUTE
    if defaultRoute and interfaces[defaultRoute] and defaultRoute ~= incomingSide then
        interfaces[defaultRoute].transmit(1,1,packet)
        return
    end

    -- DROP PACKET
    print("Dropping packet to "..tostring(packet.dst).." (no route)")
end

-- ==========================
-- HELLO ROUTER PING
-- ==========================
local function pingRouters(oldIP)
    local pingPacket = {
        uid = makeUID(),
        src = routerIP,
        dst = "0",
        ttl = DEFAULT_TTL,
        payload = { type="HELLO_ROUTER", remove=oldIP }
    }
    for side, modem in pairs(interfaces) do modem.transmit(1,1,pingPacket) end
    print("Sent HELLO_ROUTER ping on all interfaces.")
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
        local cmd,arg1,arg2 = line:match("^(%S+)%s*(%S*)%s*(%S*)$")

        if cmd=="help" then printHelp()
        elseif cmd=="exit" then return
        elseif cmd=="show" then
            if arg1=="routes" then for s,t in pairs(routingTable) do print(s.." -> "..t) end
            elseif arg1=="hosts" then for h,s in pairs(hosts) do print(h.." -> "..s) end
            elseif arg1=="keywords" then for k,v in pairs(keywords) do print(k.." -> "..v) end
            else print("Usage: show routes | show hosts | show keywords") end
        elseif cmd=="set" and arg1=="ip" and arg2~="" then
            local oldIP = routerIP
            routerIP = arg2
            print("Router IP changed from "..oldIP.." to "..routerIP)
            pingRouters(oldIP)
        elseif cmd=="add" and arg1=="route" and arg2~="" then
            local subnet, side = arg2:match("([^%s]+)%s+([^%s]+)")
            if not subnet or not side or not interfaces[side] then
                print("Usage: add route <subnet> <side>")
            else routingTable[subnet] = side; print("Added route "..subnet.." -> "..side) end
        elseif cmd=="del" and arg1=="route" and arg2~="" then
            routingTable[arg2] = nil; print("Deleted route for "..arg2)
        elseif cmd=="set" and arg1=="defaultroute" and arg2~="" then
            if interfaces[arg2] then
                defaultRoute = arg2
                print("Default route set to side "..arg2)
            else
                print("Invalid side: "..arg2)
            end
        elseif cmd=="sides" then for s,_ in pairs(interfaces) do print("  "..s) end
        else print("Unknown command.") end
    end
end

-- ==========================
-- EVENT LOOP
-- ==========================
local function listener()
    while true do
        local e, side, ch, reply, msg, dist = os.pullEvent("modem_message")
        if interfaces[side] and type(msg)=="table" and msg.uid then
            forwardPacket(msg, side)
        end
    end
end

-- ==========================
-- STARTUP
-- ==========================
pingRouters()
while true do parallel.waitForAny(listener, cli) end
