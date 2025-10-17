-- cell_tower.lua v1.2
-- Acts as a wireless <-> wired bridge with its own IP address
-- Responds to ping, hello, and routes packets between networks

local VERSION = "1.2"
local DEBUG = false
local function dprint(msg) if DEBUG then print("[DEBUG] " .. msg) end end

-- CONFIGURATION
local TOWER_IP_FILE = "tower_ip.txt"
local DEFAULT_TTL = 8
local HELLO_INTERVAL = 60
local ROUTING_FILE = "tower_routes.txt"

-- INTERFACES
local wirelessSide, wiredSide = nil, nil
for _, side in ipairs({"top", "bottom", "left", "right", "front", "back"}) do
    local ptype = peripheral.getType(side)
    if ptype == "modem" then
        local modem = peripheral.wrap(side)
        if modem.isWireless() then
            wirelessSide = side
        else
            wiredSide = side
        end
    end
end

if not wirelessSide or not wiredSide then
    error("Missing modems! Require one wireless and one wired modem.")
end

local wireless = peripheral.wrap(wirelessSide)
local wired = peripheral.wrap(wiredSide)
wireless.open(1)
wired.open(1)
print("Wireless: " .. wirelessSide .. ", Wired: " .. wiredSide)

-- LOAD OR CREATE IP
local towerIP
if fs.exists(TOWER_IP_FILE) then
    local f = fs.open(TOWER_IP_FILE, "r")
    towerIP = f.readLine()
    f.close()
else
    towerIP = "10.20." .. math.random(10,99) .. "." .. os.getComputerID()
    local f = fs.open(TOWER_IP_FILE, "w")
    f.writeLine(towerIP)
    f.close()
    print("Assigned IP: " .. towerIP)
end

-- STATE
local seen = {}
local lastSeen = {}
local hosts = {}
local routingTable = {}

-- UTILS
local function makeUID()
    return tostring(os.clock()) .. "-" .. tostring(math.random(1,99999))
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

local function learnHost(ip, side)
    if not ip or not side then return end
    if hosts[ip] ~= side then
        hosts[ip] = side
        lastSeen[ip] = os.clock()
        dprint("Learned host " .. ip .. " via " .. side)
    else
        lastSeen[ip] = os.clock()
    end
end

-- SEND FUNCTIONS
local function transmit(side, packet)
    if side == "wireless" then
        wireless.transmit(1,1,packet)
    elseif side == "wired" then
        wired.transmit(1,1,packet)
    end
end

local function broadcast(packet)
    wireless.transmit(1,1,packet)
    wired.transmit(1,1,packet)
end

-- PACKET HANDLER
local function handlePacket(packet, incoming)
    if not packet or type(packet) ~= "table" or not packet.uid then return end
    if seen[packet.uid] then return end
    seen[packet.uid] = true

    packet.ttl = (packet.ttl or DEFAULT_TTL) - 1
    if packet.ttl <= 0 then return end

    local payload = packet.payload

    -- Learn the source
    learnHost(packet.src, incoming)

    -- Handle HELLO
    if type(payload) == "table" then
        if payload.type == "HELLO_REQUEST" then
            -- Reply
            local reply = { uid = makeUID(), src = towerIP, dst = packet.src, ttl = DEFAULT_TTL, payload = { type = "HELLO_REPLY" } }
            transmit(incoming, reply)
            -- Rebroadcast to other network
            if incoming == "wireless" then
                wired.transmit(1,1,packet)
            else
                wireless.transmit(1,1,packet)
            end
            return
        elseif payload.type == "HELLO_REPLY" then
            learnHost(packet.src, incoming)
            return
        elseif payload.type == "PING" then
            if packet.dst == towerIP then
                local pong = { uid = makeUID(), src = towerIP, dst = packet.src, ttl = DEFAULT_TTL, payload = { type="PING_REPLY", message="pong" } }
                transmit(incoming, pong)
                print("Ping reply sent to " .. packet.src)
                return
            end
        end
    end

    -- Forward other packets across networks
    if incoming == "wireless" then
        wired.transmit(1,1,packet)
    else
        wireless.transmit(1,1,packet)
    end
end

-- PERIODIC HELLO
local function periodicHello()
    while true do
        local hello = { uid = makeUID(), src = towerIP, dst = "0", ttl = DEFAULT_TTL, payload = { type="HELLO_REQUEST" } }
        broadcast(hello)
        os.sleep(HELLO_INTERVAL)
    end
end

-- LISTENER
local function listener()
    while true do
        local e, side, ch, reply, msg, dist = os.pullEvent("modem_message")
        local net = (side == wirelessSide) and "wireless" or "wired"
        handlePacket(msg, net)
    end
end

-- CLI
local function cli()
    while true do
        write("(tower "..towerIP..")> ")
        local line = read()
        if line == "exit" then
            print("Shutting down tower...")
            return
        elseif line == "show hosts" then
            for h,s in pairs(hosts) do print(h.." -> "..s) end
        elseif line == "ping self" then
            print("Tower IP: "..towerIP)
        elseif line == "help" then
            print("Commands:\n  show hosts\n  ping self\n  exit")
        else
            print("Unknown command.")
        end
    end
end

-- AUTOSTART
local function ensureStartup()
    if not fs.exists("startup") then
        local f = fs.open("startup","w")
        f.writeLine("shell.run('cell_tower.lua')")
        f.close()
        print("Startup configured for cell_tower.lua")
    else
        local f = fs.open("startup","r")
        local content = f.readAll()
        f.close()
        if not content:match("cell_tower.lua") then
            local f2 = fs.open("startup","a")
            f2.writeLine("shell.run('cell_tower.lua')")
            f2.close()
            print("Added cell_tower.lua to startup.")
        end
    end
end

ensureStartup()

-- START
print("Cell Tower active at "..towerIP)
parallel.waitForAny(listener, periodicHello, cli)
