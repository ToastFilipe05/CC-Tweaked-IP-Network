-- router.lua Version 1.4
-- Secure router with persistent routing, password CLI, clean autostart, safe termination
-- Adds host-server discovery and host update propagation (diff + full)

-- ==========================
-- SELF-LAUNCH IN MULTISHELL (Forge-safe)
-- ==========================
if type(multishell) == "table" and type(multishell.getCurrent) == "function" then
    local currentProgram = shell.getRunningProgram()
    if multishell.getCurrent() == 1 then
        multishell.launch(shell, currentProgram)
        return
    end
end

-- ==========================
-- CONFIGURATION
-- ==========================
local sides = {"left","right","top","bottom","front","back"}
local DEFAULT_TTL = 8
local HELLO_INTERVAL = 60
local HOST_DISCOVER_INTERVAL = 30
local HOST_UPDATE_INTERVAL = 600 -- router will relay updates periodic if it is connected (but host server sends updates every 600)
local CLI_PASSWORD = "Admin"
local ROUTING_FILE = "routing_table.txt"
local IP_FILE = "ip.txt"

-- ==========================
-- STATE
-- ==========================
local interfaces = {}
local hosts = {}         -- host ip -> side (learned via HELLO_REPLY)
local hostNames = {}     -- name -> ip (local host table received from host server)
local keywords = {}
local lastSeen = {}
local seen = {}
local routingTable = {}
local defaultRoute = nil
local routerIP
local terminated = false
local hostServerInfo = nil -- { ip = "x.x.x.x", side = "left" }
local isHostServer = false

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
                if subnet and side then routingTable[subnet] = side end
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
    if peripheral.getType(side) == "modem" then
        local m = peripheral.wrap(side)
        interfaces[side] = m
        m.open(1)
        print("Opened modem on side "..side)
    end
end
if next(interfaces) == nil then error("No modems found!") end

loadRoutingTable()

-- ==========================
-- PACKET UTILS
-- ==========================
local function sendPacketOnSide(side, dst, payload)
    if not routerIP then return end
    if not interfaces[side] then return end
    local packet = { uid = makeUID(), src = routerIP, dst = dst, ttl = DEFAULT_TTL, payload = payload }
    interfaces[side].transmit(1,1,packet)
end

local function sendPacket(dst, payload)
    if not routerIP then
        print("Set your IP first with 'set ip <ip>' before sending packets.")
        return
    end
    local resolved = dst
    local packet = { uid = makeUID(), src = routerIP, dst = resolved, ttl = DEFAULT_TTL, payload = payload }
    -- broadcast to all interfaces (default behavior)
    for side, m in pairs(interfaces) do m.transmit(1,1,packet) end
end

-- ==========================
-- HOST SERVER DISCOVERY & HOSTS SYNC
-- ==========================
-- Packet types:
-- DISCOVER_HOST_SERVER -> broadcast by router to find host servers
-- HOST_SERVER_HERE { server_ip } -> reply when router knows server or is connected
-- REQUEST_HOSTS -> request full hosts table
-- UPDATE_HOSTS { full=true, hosts = {...} } -> full update from host server
-- HOSTS_DIFF { diff = {added={}, removed={}, updated={}} } -> diff update

local function broadcastDiscoverHostServer()
    local payload = { type = "DISCOVER_HOST_SERVER" }
    for side, m in pairs(interfaces) do m.transmit(1,1,{ uid = makeUID(), src = routerIP, dst = "0", ttl = DEFAULT_TTL, payload = payload }) end
end

local function handleHostServerHere(srcIP, incomingSide, payload)
    -- payload.server_ip may be provided; srcIP is the packet sender
    local serverIP = payload.server_ip or srcIP
    hostServerInfo = { ip = serverIP, side = incomingSide }
    -- add route for server's subnet
    local subnet = serverIP:match("^(%d+%.%d+%.%d+)")
    if subnet and not routingTable[subnet] then
        routingTable[subnet] = incomingSide
        saveRoutingTable()
        print("Host server discovered at "..serverIP.." via "..incomingSide.." added route "..subnet.." -> "..incomingSide)
    end
    -- if this router's IP equals serverIP, mark as host server
    if routerIP == serverIP then
        isHostServer = true
        print("This router is the host server (self-identification).")
    end
    -- request full hosts on discovery
    sendPacketOnSide(incomingSide, serverIP, { type = "REQUEST_HOSTS" })
end

-- ==========================
-- FORWARDING & PACKET HANDLING
-- ==========================
local function forwardPacket(packet, incomingSide)
    if seen[packet.uid] then return end
    seen[packet.uid] = true
    packet.ttl = (packet.ttl or DEFAULT_TTL) - 1
    if packet.ttl <= 0 then return end

    if type(packet.payload) == "table" then
        local payload = packet.payload

        if payload.type == "HELLO_REPLY" then
            hosts[packet.src] = incomingSide
            lastSeen[packet.src] = os.clock()
            local subnet = packet.src:match("^(%d+%.%d+%.%d+)")
            routingTable[subnet] = incomingSide
            if payload.keyword then keywords[payload.keyword] = packet.src end
            print("Discovered host "..packet.src.." via "..incomingSide)
            saveRoutingTable()
            return
        elseif payload.type == "HELLO_REQUEST" then
            local reply = { uid = makeUID(), src = routerIP, dst = packet.src, ttl = DEFAULT_TTL, payload = { type = "HELLO_REPLY" } }
            interfaces[incomingSide].transmit(1,1,reply)
            print("Replied to HELLO_REQUEST from "..packet.src)
            return
        elseif payload.type == "PING" then
            local reply = { uid = makeUID(), src = routerIP, dst = packet.src, ttl = DEFAULT_TTL, payload = { type = "PING_REPLY", message = "pong" } }
            interfaces[incomingSide].transmit(1,1,reply)
            print("Replied to PING from "..packet.src)
            return
        elseif payload.type == "DISCOVER_HOST_SERVER" then
            -- If this router knows host server or is directly connected to it, respond
            if hostServerInfo and hostServerInfo.ip then
                -- reply back towards requesting router
                sendPacketOnSide(incomingSide, packet.src, { type = "HOST_SERVER_HERE", server_ip = hostServerInfo.ip })
                print("Informed "..packet.src.." of host server at "..hostServerInfo.ip)
            else
                -- if directly connected (we could check our local host list or services) skip
            end
            -- do not forward DISCOVER to avoid loops (we broadcast periodically anyway)
            return
        elseif payload.type == "HOST_SERVER_HERE" then
            handleHostServerHere(packet.src, incomingSide, payload)
            return
        elseif payload.type == "REQUEST_HOSTS" then
            -- If this router IS the host server, respond with full hosts
            if isHostServer and type(_G.hostServer_getFullHosts) == "function" then
                local full = _G.hostServer_getFullHosts()
                sendPacketOnSide(incomingSide, packet.src, { type = "UPDATE_HOSTS", hosts = full })
                print("Responded to REQUEST_HOSTS from "..packet.src)
            else
                -- If we know where host server is, forward request towards host server
                if hostServerInfo and hostServerInfo.ip and routingTable[hostServerInfo.ip:match("^(%d+%.%d+%.%d+)")] then
                    local sideToServer = routingTable[hostServerInfo.ip:match("^(%d+%.%d+%.%d+)")]
                    interfaces[sideToServer].transmit(1,1,packet)
                end
            end
            return
        elseif payload.type == "UPDATE_HOSTS" then
            -- full update included
            if type(payload.hosts) == "table" then
                -- write to local hosts file: name ip
                local f = fs.open("hosts.txt","w")
                for name, info in pairs(payload.hosts) do
                    f.writeLine(name.." "..tostring(info.ip))
                end
                f.close()
                -- also write flags
                local f2 = fs.open("hosts_flags.txt","w")
                f2.writeLine(textutils.serialize((function(tbl)local out={} for n,i in pairs(tbl) do out[n]=i.flags or {} end return out end)(payload.hosts)))
                f2.close()
                print("Hosts updated from host server (full).")
            end
            return
        elseif payload.type == "HOSTS_DIFF" then
            -- relay diff to local clients (broadcast) and update local hosts.txt by applying diff
            if type(payload.diff) == "table" then
                -- Apply to local hosts file
                -- load current hosts
                local localHosts = {}
                if fs.exists("hosts.txt") then
                    local f = fs.open("hosts.txt","r")
                    while true do
                        local line = f.readLine()
                        if not line then break end
                        local k, ip = line:match("^(%S+)%s+(%S+)$")
                        if k and ip then localHosts[k] = ip end
                    end
                    f.close()
                end
                -- removed
                if type(payload.diff.removed) == "table" then
                    for _, name in ipairs(payload.diff.removed) do localHosts[name] = nil end
                end
                -- added/updated
                if type(payload.diff.added) == "table" then
                    for name,info in pairs(payload.diff.added) do localHosts[name] = info.ip end
                end
                if type(payload.diff.updated) == "table" then
                    for name,info in pairs(payload.diff.updated) do localHosts[name] = info.ip end
                end
                -- save back
                local f = fs.open("hosts.txt","w")
                for name,ip in pairs(localHosts) do f.writeLine(name.." "..ip) end
                f.close()
                print("Hosts file updated (diff applied).")
                -- Broadcast diff to local clients (dst "0" to reach all)
                local relayPacket = { uid = makeUID(), src = routerIP, dst = "0", ttl = DEFAULT_TTL, payload = { type = "HOSTS_DIFF", diff = payload.diff } }
                for side,m in pairs(interfaces) do m.transmit(1,1,relayPacket) end
            end
            return
        end
    end

    -- Normal forwarding logic
    if packet.dst == routerIP then
        print(("Packet for router: %s"):format(textutils.serialize(packet.payload)))
        return
    end

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
    if defaultRoute and interfaces[defaultRoute] and defaultRoute ~= incomingSide then
        interfaces[defaultRoute].transmit(1,1,packet)
        return
    end

    print("Dropping packet to "..tostring(packet.dst).." (no route)")
end

-- ==========================
-- PERIODIC TASKS
-- ==========================
local function periodicHelloCheck()
    while not terminated do
        local packet = { uid = makeUID(), src = routerIP, dst = "0", ttl = DEFAULT_TTL, payload = { type = "HELLO_REQUEST" } }
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

local function periodicDiscoverHostServer()
    while not terminated do
        broadcastDiscoverHostServer()
        os.sleep(HOST_DISCOVER_INTERVAL)
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
        if interfaces[side] and type(msg) == "table" and msg.uid then
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
-- Start background tasks: listener, CLI, periodic hello, host discovery
parallel.waitForAny(listener, cli, periodicHelloCheck, periodicDiscoverHostServer)
