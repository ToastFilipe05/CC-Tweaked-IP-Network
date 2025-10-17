-- router.lua Version 1.62
-- Secure router with persistent routing, password CLI, clean autostart, safe termination
-- Fixes: ensure route learning works, robust broadcast forwarding, monitor output

-- SELF-LAUNCH IN MULTISHELL (Forge-safe)
if type(multishell) == "table" and type(multishell.getCurrent) == "function" then
    local currentProgram = shell.getRunningProgram()
    if multishell.getCurrent() == 1 then
        multishell.launch(shell, currentProgram)
        return
    end
end

-- ==========================
-- DEBUG MODE
-- ==========================
local DEBUG = false
local function debugPrint(msg)
    if DEBUG then print("[DEBUG] " .. msg) end
end


-- MONITOR SETUP + INFO LOGGING
local monitorSide = "top" -- change if your monitor is on a different side
local mon = peripheral.isPresent(monitorSide) and peripheral.wrap(monitorSide)

local function logInfo(msg)
    if mon then
        local x, y = mon.getCursorPos()
        local w, h = mon.getSize()
        if y >= h then
            mon.scroll(1)
            y = h - 1
        end
        mon.setCursorPos(1, y + 1)
        mon.write(msg)
    else
        print(msg)
    end
end

-- CONFIGURATION
local sides = {"left","right","top","bottom","front","back"}
local DEFAULT_TTL = 8
local HELLO_INTERVAL = 60
local CLI_PASSWORD = "Admin"
local ROUTING_FILE = "routing_table.txt"
local IP_FILE = "ip.txt"

-- STATE
local interfaces = {}
local hosts = {}         -- host ip -> side (learned via HELLO_REPLY)
local lastSeen = {}
local seen = {}
local routingTable = {}
local defaultRoute = nil
local routerIP
local terminated = false

-- UTILITIES
local function makeUID()
    return tostring(os.clock()).."-"..tostring(math.random(1,99999))
end

local function splitIP(ip)
    if not ip then return nil,nil,nil end
    local a,b,c = ip:match("(%d+)%.(%d+)%.(%d+)")
    return tonumber(a), tonumber(b), tonumber(c)
end

local function matchSubnet(ip, subnet)
    local a1,b1,c1 = splitIP(ip)
    local a2,b2,c2 = splitIP(subnet)
    if not a1 or not a2 then return false end
    return a1==a2 and b1==b2 and c1==c2
end

local function saveRoutingTable()
    local f = fs.open(ROUTING_FILE,"w")
    for subnet, side in pairs(routingTable) do
        f.writeLine(subnet.." "..side)
    end
    if defaultRoute then f.writeLine("default "..defaultRoute) end
    f.close()
end

local function loadRoutingTable()
    routingTable = {}
    defaultRoute = defaultRoute
    if fs.exists(ROUTING_FILE) then
        local f = fs.open(ROUTING_FILE,"r")
        while true do
            local line = f.readLine()
            if not line then break end
            if line:match("^default") then
                defaultRoute = line:match("^default%s+(%S+)")
            else
                local subnet, side = line:match("^(%S+)%s+(%S+)$")
                if subnet and side then routingTable[subnet] = side end
            end
        end
        f.close()
    end
end

-- LOAD OR CREATE IP
if not fs.exists(IP_FILE) then
    routerIP = "10.10.10."..os.getComputerID()
    local f = fs.open(IP_FILE,"w")
    f.writeLine(routerIP)
    f.close()
    logInfo("Created "..IP_FILE.." with default IP: "..routerIP)
else
    local f = fs.open(IP_FILE,"r")
    routerIP = f.readLine()
    f.close()
    logInfo("Loaded router IP from "..IP_FILE..": "..routerIP)
end

local function updateIPFile()
    local f = fs.open(IP_FILE,"w")
    f.writeLine(routerIP)
    f.close()
end

-- SETUP INTERFACES
for _, side in ipairs(sides) do
    if peripheral.getType(side) == "modem" then
        local m = peripheral.wrap(side)
        interfaces[side] = m
        -- open channel 1 for all modems we find
        pcall(function() m.open(1) end)
        logInfo("Opened modem on side "..side)
    end
end
if next(interfaces) == nil then error("No modems found!") end

loadRoutingTable()

-- PACKET UTILS
local function sendPacketOnSide(side, dst, payload)
    if not routerIP or not interfaces[side] then return end
    local packet = { uid = makeUID(), src = routerIP, dst = dst, ttl = DEFAULT_TTL, payload = payload }
    interfaces[side].transmit(1,1,packet)
end

local function broadcastOnAllExcept(incomingSide, packet)
    for side, m in pairs(interfaces) do
        if side ~= incomingSide then
            m.transmit(1,1,packet)
        end
    end
end

local function sendPacket(dst, payload)
    if not routerIP then
        logInfo("Set your IP first with 'set ip <ip>' before sending packets.")
        return
    end
    local packet = { uid = makeUID(), src = routerIP, dst = dst, ttl = DEFAULT_TTL, payload = payload }
    for side, m in pairs(interfaces) do m.transmit(1,1,packet) end
end

-- FORWARDING & PACKET HANDLING
local function learnHostRoute(srcIP, incomingSide)
    if not srcIP then return end
    if hosts[srcIP] ~= incomingSide then
        hosts[srcIP] = incomingSide
        lastSeen[srcIP] = os.clock()
        local subnet = srcIP:match("^(%d+%.%d+%.%d+)")
        if subnet then
            routingTable[subnet] = incomingSide
        end
        saveRoutingTable()
        logInfo("Learned host "..srcIP.." via "..incomingSide.." (added route "..(subnet or "nil").." -> "..incomingSide..")")
    else
        lastSeen[srcIP] = os.clock()
    end
end

local function forwardPacket(packet, incomingSide)
    if not packet or type(packet) ~= "table" or not packet.uid then return end
    if seen[packet.uid] then return end
    seen[packet.uid] = true
    packet.ttl = (packet.ttl or DEFAULT_TTL) - 1
    if packet.ttl <= 0 then return end

    local payload = packet.payload

    -- If packet has table payload, process known types first (so router learns any necessary info)
    if type(payload) == "table" then
        if payload.type == "HELLO_REPLY" then
            -- learn the host immediately
            learnHostRoute(packet.src, incomingSide)
            return
        elseif payload.type == "HELLO_REQUEST" then
            -- reply back to requester on same side it came from
            local reply = { uid = makeUID(), src = routerIP, dst = packet.src, ttl = DEFAULT_TTL, payload = { type = "HELLO_REPLY" } }
            interfaces[incomingSide].transmit(1,1,reply)
            debugPrint("Replied to HELLO_REQUEST from "..packet.src)
            -- also broadcast the HELLO_REQUEST to other sides (so other networks can see it)
            broadcastOnAllExcept(incomingSide, packet)
            return
        elseif payload.type == "PING" then
            if packet.dst == routerIP then
            	local reply = { uid = makeUID(), src = routerIP, dst = packet.src, ttl = DEFAULT_TTL, payload = { type = "PING_REPLY", 					message = "pong" } }
            	interfaces[incomingSide].transmit(1,1,reply)
            	logInfo("Replied to PING from "..packet.src)
             else
             	--contiue with forwarding logic
             end
        end
    end

    -- Non-payload or after payload handling: Unicast & Normal forwarding
    -- If destination is broadcast, forward to all other sides
    if packet.dst == "0" then
        broadcastOnAllExcept(incomingSide, packet)
        return
    end

    -- If packet is destined to this router, process locally
    if packet.dst == routerIP then
        logInfo(("Packet for router: %s"):format(textutils.serialize(packet.payload)))
        return
    end

    -- If we know a direct host mapping, send there (avoid sending back to incoming side)
    local targetSide = hosts[packet.dst]
    if targetSide and interfaces[targetSide] then
        if targetSide ~= incomingSide then
            interfaces[targetSide].transmit(1,1,packet)
            return
        else
            -- if target is on incoming side, nothing to do (already on that side)
            return
        end
    end

    -- Otherwise, try subnet routing
    for subnet, side in pairs(routingTable) do
        if matchSubnet(packet.dst, subnet) and interfaces[side] then
            if side ~= incomingSide then
                interfaces[side].transmit(1,1,packet)
            end
            return
        end
    end

    -- Fallback: default route if available
    if defaultRoute and interfaces[defaultRoute] and defaultRoute ~= incomingSide then
        interfaces[defaultRoute].transmit(1,1,packet)
        return
    end

    -- No route found
    logInfo("Dropping packet to "..tostring(packet.dst).." (no route)")
end

-- PERIODIC TASKS
local function periodicHelloCheck()
    while not terminated do
        local packet = { uid = makeUID(), src = routerIP, dst = "0", ttl = DEFAULT_TTL, payload = { type = "HELLO_REQUEST" } }
        for side, modem in pairs(interfaces) do modem.transmit(1,1,packet) end

        local now = os.clock()
        for host, t in pairs(lastSeen) do
            if now - t > HELLO_INTERVAL then
                logInfo("Host timed out: "..host)
                hosts[host] = nil
                lastSeen[host] = nil
                local subnet = host:match("^(%d+%.%d+%.%d+)")
                routingTable[subnet] = nil
                saveRoutingTable()
            end
        end
        os.sleep(HELLO_INTERVAL)
    end
end

-- CLI
local function printHelp()
    print([[Router Commands:
  show routes
  show hosts
  ip set <ip>
  add route <subnet> <side>
  del route <subnet>
  set defaultroute <side>
  sides
  exit
  terminate
  help]])
end

local function cli()
    while not terminated do
        io.write("Enter router CLI password: ")
        local input = read("*")
        if input ~= CLI_PASSWORD then
            print("Incorrect password.")
            os.sleep(1)
        else
            print("Access granted. Router CLI started.")
            while true do
                io.write("(router)> ")
                local line = read()
                if not line then break end
                local cmd,arg1,arg2,arg3 = line:match("^(%S+)%s*(%S*)%s*(%S*)%s*(%S*)$")
                if cmd=="help" then printHelp()
                elseif cmd=="exit" then term.clear() term.setCursorPos(1,1) break
                elseif cmd=="terminate" then
                    print("Enter password to confirm termination:")
                    local check = read("*")
                    if check == CLI_PASSWORD then
                        logInfo("Router shutting down...")
                        terminated = true
                        return
                    else
                        print("Incorrect password. Abort termination.")
                    end
                elseif cmd=="show" then
                    if arg1=="routes" then for s,t in pairs(routingTable) do print(s.." -> "..t) end
                    elseif arg1=="hosts" then for h,s in pairs(hosts) do print(h.." -> "..s) end
                    else print("Usage: show routes | show hosts") end
                elseif cmd=="ip" and arg1=="set" and arg2~="" then
                    routerIP = arg2
                    updateIPFile()
                    logInfo("Router IP updated to "..routerIP)
                elseif cmd=="add" and arg1=="route" and arg2~="" and arg3~="" then
                    if not interfaces[arg3] then print("Invalid side: "..arg3)
                    else routingTable[arg2] = arg3; logInfo("Added route "..arg2.." -> "..arg3); saveRoutingTable() end
                elseif cmd=="del" and arg1=="route" and arg2~="" then
                    routingTable[arg2] = nil; logInfo("Deleted route for "..arg2); saveRoutingTable()
                elseif cmd=="set" and arg1=="defaultroute" and arg2~="" then
                    if interfaces[arg2] then defaultRoute = arg2; logInfo("Default route set to "..arg2); saveRoutingTable()
                    else print("Invalid side: "..arg2) end
                elseif cmd=="sides" then for s,_ in pairs(interfaces) do print("  "..s) end
                else print("Unknown command.") end
            end
        end
    end
end

-- EVENT LOOP
local function listener()
    while not terminated do
        local e, side, ch, reply, msg, dist = os.pullEvent("modem_message")
        if interfaces[side] and type(msg)=="table" and msg.uid then
            forwardPacket(msg, side)
        end
    end
end

-- AUTOSTART SETUP
local function ensureStartup()
    local startupContent = ""
    if fs.exists("startup") then
        local f = fs.open("startup","r")
        startupContent = f.readAll()
        f.close()
    end
    if not startupContent:match("shell%.run%(\'router.lua\'%)") then
        local f = fs.open("startup","a")
        f.writeLine("shell.run('router.lua')")
        f.close()
        logInfo("Router auto-start added to startup.")
    else
        logInfo("Router already configured to auto-start.")
    end
end

ensureStartup()

-- STARTUP
parallel.waitForAny(listener, cli, periodicHelloCheck)
