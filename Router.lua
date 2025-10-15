-- router.lua Version 1.3
-- Secure router with persistent routing, password CLI, clean autostart, and safe termination

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
local terminated = false

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

local function saveRoutingTable()
    local f = fs.open(ROUTING_FILE,"w")
    for subnet, side in pairs(routingTable) do
        f.writeLine(subnet.." "..side)
    end
    if defaultRoute then f.writeLine("default "..defaultRoute) end
    f.close()
end

local function loadRoutingTable()
    if fs.exists(ROUTING_FILE) then
        local f = fs.open(ROUTING_FILE,"r")
        while true do
            local line = f.readLine()
            if not line then break end
            if line:match("^default") then
                defaultRoute = line:match("^default%s+(%S+)")
            else
                local subnet, side = line:match("^(%S+)%s+(%S+)$")
                if subnet and side then routingTable[subnet]=side end
            end
        end
        f.close()
    end
end

-- ==========================
-- LOAD OR CREATE IP
-- ==========================
if not fs.exists(IP_FILE) then
    routerIP = "10.10.10."..os.getComputerID()
    local f = fs.open(IP_FILE,"w")
    f.writeLine(routerIP)
    f.close()
    print("Created "..IP_FILE.." with default IP: "..routerIP)
else
    local f = fs.open(IP_FILE,"r")
    routerIP = f.readLine()
    f.close()
    print("Loaded router IP from "..IP_FILE..": "..routerIP)
end

local function updateIPFile()
    local f = fs.open(IP_FILE,"w")
    f.writeLine(routerIP)
    f.close()
end

-- ==========================
-- SETUP INTERFACES
-- ==========================
for _, side in ipairs(sides) do
    if peripheral.getType(side)=="modem" then
        local m = peripheral.wrap(side)
        interfaces[side] = m
        m.open(1)
        print("Opened modem on side "..side)
    end
end
if next(interfaces)==nil then error("No modems found!") end

loadRoutingTable()

-- ==========================
-- PACKET FORWARDING
-- ==========================
local function forwardPacket(packet, incomingSide)
    if seen[packet.uid] then return end
    seen[packet.uid] = true
    packet.ttl = (packet.ttl or DEFAULT_TTL) - 1
    if packet.ttl<=0 then return end

    if type(packet.payload)=="table" then
        local payload = packet.payload

        if payload.type=="HELLO_REPLY" then
            hosts[packet.src] = incomingSide
            lastSeen[packet.src] = os.clock()
            local subnet = packet.src:match("^(%d+%.%d+%.%d+)")
            routingTable[subnet] = incomingSide
            if payload.keyword then keywords[payload.keyword]=packet.src end
            print("Discovered host "..packet.src.." via "..incomingSide)
            saveRoutingTable()
            return
        elseif payload.type=="HELLO_REQUEST" then
            local reply = { uid=makeUID(), src=routerIP, dst=packet.src, ttl=DEFAULT_TTL, payload={ type="HELLO_REPLY" } }
            interfaces[incomingSide].transmit(1,1,reply)
            print("Replied to HELLO_REQUEST from "..packet.src)
            return
        elseif payload.type=="PING" then
            local reply = { uid=makeUID(), src=routerIP, dst=packet.src, ttl=DEFAULT_TTL, payload={ type="PING_REPLY", message="pong" } }
            interfaces[incomingSide].transmit(1,1,reply)
            print("Replied to PING from "..packet.src)
        end
    end

    if packet.dst==routerIP then
        print(("Packet for router: %s"):format(textutils.serialize(packet.payload)))
        return
    end

    local targetSide = hosts[packet.dst]
    if targetSide and targetSide~=incomingSide then
        interfaces[targetSide].transmit(1,1,packet)
        return
    end
    for subnet, side in pairs(routingTable) do
        if matchSubnet(packet.dst,subnet) and side~=incomingSide then
            interfaces[side].transmit(1,1,packet)
            return
        end
    end
    if defaultRoute and interfaces[defaultRoute] and defaultRoute~=incomingSide then
        interfaces[defaultRoute].transmit(1,1,packet)
        return
    end

    print("Dropping packet to "..tostring(packet.dst).." (no route)")
end

-- ==========================
-- PERIODIC HELLO + TIMEOUT
-- ==========================
local function periodicHelloCheck()
    while not terminated do
        local packet = { uid=makeUID(), src=routerIP, dst="0", ttl=DEFAULT_TTL, payload={ type="HELLO_REQUEST" } }
        for side, modem in pairs(interfaces) do modem.transmit(1,1,packet) end

        local now = os.clock()
        for host, t in pairs(lastSeen) do
            if now - t > HELLO_INTERVAL then
                print("Host timed out: "..host)
                hosts[host] = nil
                lastSeen[host] = nil
                local subnet = host:match("^(%d+%.%d+%.%d+)")
                routingTable[subnet] = nil
                for k,v in pairs(keywords) do if v==host then keywords[k]=nil end end
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
                        print("Router shutting down...")
                        terminated = true
                        return
                    else
                        print("Incorrect password. Abort termination.")
                    end
                elseif cmd=="show" then
                    if arg1=="routes" then for s,t in pairs(routingTable) do print(s.." -> "..t) end
                    elseif arg1=="hosts" then for h,s in pairs(hosts) do print(h.." -> "..s) end
                    elseif arg1=="keywords" then for k,v in pairs(keywords) do print(k.." -> "..v) end
                    else print("Usage: show routes | show hosts | show keywords") end
                elseif cmd=="set" and arg1=="ip" and arg2~="" then
                    routerIP = arg2
                    updateIPFile()
                    print("Router IP updated to "..routerIP)
                elseif cmd=="add" and arg1=="route" and arg2~="" and arg3~="" then
                    if not interfaces[arg3] then print("Invalid side: "..arg3)
                    else routingTable[arg2]=arg3; print("Added route "..arg2.." -> "..arg3); saveRoutingTable() end
                elseif cmd=="del" and arg1=="route" and arg2~="" then
                    routingTable[arg2]=nil; print("Deleted route for "..arg2); saveRoutingTable()
                elseif cmd=="set" and arg1=="defaultroute" and arg2~="" then
                    if interfaces[arg2] then defaultRoute=arg2; print("Default route set to "..arg2); saveRoutingTable()
                    else print("Invalid side: "..arg2) end
                elseif cmd=="sides" then for s,_ in pairs(interfaces) do print("  "..s) end
                else print("Unknown command.") end
            end
        end
    end
end

-- ==========================
-- EVENT LOOP
-- ==========================
local function listener()
    while not terminated do
        local e, side, ch, reply, msg, dist = os.pullEvent("modem_message")
        if interfaces[side] and type(msg)=="table" and msg.uid then
            forwardPacket(msg, side)
        end
    end
end

-- ==========================
-- AUTOSTART SETUP
-- ==========================
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
        print("Router auto-start added to startup.")
    else
        print("Router already configured to auto-start.")
    end
end

ensureStartup()

-- ==========================
-- STARTUP
-- ==========================
parallel.waitForAny(listener, cli, periodicHelloCheck)
