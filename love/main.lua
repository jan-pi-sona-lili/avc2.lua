table.remove(arg,1)
if ({["-h"]=1,["--help"]=1,["-?"]=1})[arg[1]] or arg[1]==nil then
	print("\27[1mNAME\27[0m\n\tavc2.love - a löve2d avc2 emulator\n\n\27[1mSYNOPSIS\27[0m\n\t\27[1mlove avc2.love\27[0m \27[4mROM\27[0m.avcr [\27[4mDRIVE\27[0m.avd]\n\t\27[1mlove avc2.love\27[0m [\27[1m-h\27[0m|\27[1m-?\27[0m|\27[1m--help\27[0m]\n\n\27[1mDESCRIPTION\27[0m\n\t\27[1mavc2.love\27[0m is an avc2 (https://github.com/ambyshframber/avc2) emulator, written in luajit (with tweaks for löve2d).\n\tThere are some things that should be noted for this emulator:\n\t· ALL operations can accept signed values (i.e. one can JMP backwards by using a negative value). This may be changed in the future.\n\t· ADC and SBC are probably broken slightly.\n\t· as it turns out, reading IO in a non-blocking fashion is far harder than it should be, and is currently not implemented in Windows.")
	os.exit()
end


setmetatable(_G, {__newindex=function()error("attempt to use global value (bad)")end})

--> requires
local string = require("string")local byte, sub, char,rep = string.byte, string.sub, string.char, string.rep
local table  = require("table")local concat = table.concat
local io     = require("io")
local os     = require("os")
local math   = require("math")
local bit    = require("bit") local band = bit.band local bor = bit.bor local lshift = bit.lshift local rshift = bit.rshift local xor = bit.xor
local ffi    = require("ffi")
local jit    = require("jit")

--              zero_page working_stack return_stack program devices
local bs     = {0x0000    ,0x0100       ,0x0200,     0x0300, 0xff00}
local be     = {0x00ff    ,0x01ff       ,0x02ff,     0xfeff, 0xffff}
--"boundary start" "boundary end"

local m      = {}       -- table used to interface with the actual memory (following three variables)
local usgn_m = ffi.new("uint8_t[65280]")
local sign_m = ffi.new( "int8_t[65280]")
local bool_m = ffi.new(   "bool[65280]")

--> registers
local wsp    = 0        -- working stack pointer
local rsp    = 0        -- return  stack pointer
local st     = 0        -- status
local pc     = 0x0300   -- program counter

--> misc other variables + settings
local buffer = ""
local halt   = false    -- if true, cleanly exit the program
local hibyte = 0        -- hi- ...
local lobyte = 0        -- ... and lobyte for the drive device
local page   = 0        -- memory page number for drive device
local write  = io.write -- aliasing for slight speedup + easier to type
local nop    = function()end
io.stdout:setvbuf("no") -- immediately flushes stdout upon writes (this is necessary to prevent duplication)

do
	math.randomseed(require("random_seed")[1])
	local seed = io.open("random_seed.lua", "w+")
	seed:write("return{",math.random(0, 2^51),"}")
	seed:close()
end --get a different random number each time


--> ffi stuff
ffi.cdef([[
void Sleep(int ms);

typedef struct pollfd { int fd; short events; short revents; } pollfd;
int poll(struct pollfd *fds, unsigned long nfds, int timeout);

]])

local sleep  = (ffi.os=="Windows" and function(s)ffi.C.Sleep(s)end or function(s)ffi.C.poll(nil, 0, s)end) --> nil
local pollfd = ffi.new("pollfd[1]", {{0,1,0}})
local read   = (ffi.os=="Windows" and nop or --TODO
function(n)
	if ffi.C.poll(pollfd, 1, (n or 0))==1 then
		local file = io.popen("bash -c 'IFS= read -n 1 -r line && printf \'%s\\n\'  \"$line\"'") --grey magic (it's black magic but it only kind of works)
		buffer = buffer..sub(file:read("*a"),1,-2)
		file:close()
	end
end) --> nil



--> WORKING STACK
local working_stack = {}
do
	local START = bs[2]
	local END   = be[2]
	function working_stack.push(number) --> nil
		--assert(type(number)=="number", "AVC2: ATTEMPT TO PUSH A NON-NUMBER TO THE WORKING STACK") --this error should never happen
		local new_location = END-wsp 
	
		if new_location >= START then
			m[new_location] = number
			wsp = wsp + 1
		else
			error("AVC2: WORKING STACK OVERFLOW")
		end
	end
	function working_stack.push2(number,number2) --> nil
		working_stack.push(number)
		working_stack.push(number2)
	end
	function working_stack.push3(number,number2,number3) --> nil
		working_stack.push(number)
		working_stack.push(number2)
		working_stack.push(number3)
	end
	function working_stack.pop() --> number|nil
		local new_location = END-wsp+1
		if new_location <= END then
			wsp = wsp - 1
			return m[new_location]
		else
			error("AVC2: WORKING STACK UNDERFLOW")
		end
	end
	function working_stack.pop2() --> number|nil, number|nil
		return working_stack.pop(), working_stack.pop()
	end
	function working_stack.pop3() --> number|nil, number|nil, number|nil
		return working_stack.pop(), working_stack.pop(), working_stack.pop()
	end
end

--> RETURN STACK STUFF
local return_stack = {}
do
	local START = bs[3]
	local END   = be[3]
	function return_stack.push(number) --> nil
		--assert(type(number)=="number", "AVC2: ATTEMPT TO PUSH A NON-NUMBER TO THE RETURN STACK") --this error should never happen
		local new_location = END-rsp

		if new_location >= START then
			m[new_location] = number
			rsp = rsp + 1
		else
			error("AVC2: RETURN STACK OVERFLOW")
		end
	end
	function return_stack.push2(number, number2) --> nil
		return_stack.push(number)
		return_stack.push(number2)
	end
	function return_stack.push3(number, number2, number3) --> nil
		return_stack.push(number)
		return_stack.push(number2)
		return_stack.push(number3)
	end
	function return_stack.pop() --> number|nil
		local new_location = END-rsp+1
		if new_location <= END then 
			rsp = rsp - 1
			return m[new_location]
		else
			error("AVC2: RETURN STACK UNDERFLOW")
		end
	end
	function return_stack.pop2() --> number|nil
		return return_stack.pop(), return_stack.pop()
	end
	function return_stack.pop3() --> number|nil
		return return_stack.pop(), return_stack.pop(), return_stack.pop()
	end
end





local z = {} -- short for 'zero page'
do 
	local START = bs[1]
	local END   = be[1]
	function z.get(address) --> number
		--if START <= address and address <= END then
			return m[address]
		--else
		--	error("AVC2: INVALID ZERO PAGE ADDRESS ACCESS") --this error should never happen
		--end
	end
	function z.store(address, number) --> nil
		--if START <= address and address <= END then
			m[address] = number
		--else
		--	error("AVC2: INVALID ZERO PAGE ADDRESS STORAGE") --this error should never happen
		--end
	end
end


local d = {} -- short for 'devices'
function d.addr(address) --> number; short for device@address
	--if band(address,0xff00)==0xff00 then
		return d[rshift(band(address,0xf0),4)+1] or setmetatable({}, {__index=function()return function()return 0 end end})
	--else
	--	error("AVC2: INVALID DEVICE ADDRESS") --this error should never happen
	--end
end
function d.new(table) --> nil
	local a = {}
	for i=1,16 do
	--	assert(table[i], "AVC2: INCOMPLETE DEVICE SPECIFICATION") --this error should never happen
		a[i-1] = ((type(table[i])~="number")and(function(n)return(table[i](n) or 0)end)or function()return table[i]end)
	end
	d[#d+1] = a
end
function d.get(address) --> number
	return d.addr(address)[band(address,0x0f)]()
end
function d.write(address, number) --> number(0)
	return d.addr(address)[band(address,0x0f)](number, address)
end



--> SYSTEM DEVICE
d.new{
--[[0 DEVID]]	1,
--[[1 WAIT]]	function(n)if n then sleep(n)end end,
--[[2 RANDOM]]	function()return math.random(0,255)end,
--[[unused]]	0,0,0,0,0,
--[[8 STDIN]]	function()local n=(buffer~=""and byte(buffer)or 0)buffer=sub(buffer,2)return n end,
--[[9 STDOUT]]	function(n)if n then write(char(n))end end,
--[[a STDERR]]	function(n)if n then io.stderr:write(char(n))end end,
--[[b BUFLEN]]	function()local l=#buffer return math.max(l, 0xff)end,
--[[unused]]	0, 0, 0,
--[[f HALT]]	function(n)if n then halt=true end end,
}



--> DRIVE DEVICE
local drive_memory
local drive = arg[2]

if drive then
	local drive_file = io.open(drive, "r")
	assert(drive_file, "AVC2: INVALID DRIVE FILE (WRONG FILE PATH?)")
	local content = drive_file:read("*a")
	drive_file:close()

	assert(sub(content, 1, 4) == "AVC\0", "AVC2: INVALID DRIVE FILE (MAGIC NUMBER INCORRECT OR MISSING)")

	drive_memory = ffi.new("uint8_t[65536][256]")

	for i = 0,((#content-4)/258)-1 do
		local address = 5 + i * 258
		local bn1,bn2 = byte(sub(content,address,address+1), 1, 2)
		local drive_address = bor(lshift(bn1, 8), bn2)
		drive_memory[drive_address] = sub(content, address + 2, address + 258)
	end

	--> DRIVE DEVICE
	d.new{
	--[[0 DEVID]]	2,
	--[[unused]]	0,
	--[[2 BLKHB]] 	function(n)if n then hibyte = n end end, 
	--[[3 BLKLB]] 	function(n)if n then lobyte = n end end, 
	--[[4 PAGE]] 	function(n)if n then page   = n end end, 
	--[[unused]]	0,0,0,
	--[[8 READ]] 	function(n)if n then for i=0,255 do m[page*256+i]=drive_memory[bor(lshift(hibyte,8),lobyte)]end end end, --TODO (both) use ffi.copy/ffi.string
	--[[9 WRITE]] 	function(n)if n then for i=0,255 do drive_memory[bor(lshift(hibyte,8),lobyte)]=m[page*256+i]end end end, --TODO
	--[[unused]]	0,0,0,0,0,0,0,
	}

end








--> MANAGE DEVICE I/O AND MEMORY ACCCESSES

local function sgn(number) --> boolean, number
	local s = number < 0
	return s, (s and -number or number) 
end
setmetatable(m,
{__index=function(t,k)
	return k<bs[5] and(bool_m[k] and sign_m[k] or usgn_m[k])or d.get(k)
end,
__newindex=function(t,k,v)
	local s = sgn(v) 
	if k<bs[5] then
		if s then
			sign_m[k] = v
			bool_m[k] = true
		else
			usgn_m[k] = v
			bool_m[k] = false
		end		
	else
		d.write(k,v)
	end
end
})




--> DEBUGGING STUFF
local function hex(number, len, space) --> string
	local sign, number = sgn(number)
	number = string.format("%x", number)
	local padded = "0x"..rep("0", len-#tostring(number))..number
	if sign then
		return " -"..padded
	else
		return (space and "  " or "")..padded
	end
end

local function print_memory(from, to) --> nil
	--write("wsp:",hex(wsp,2), "\nrsp:",hex(rsp,2), "\nst:",hex(st,2), "\npc:",hex(pc,4),"\n--------------","\n")
	for i = (from or 0),(to or 0xffff) do
		write(hex(i,4),hex(m[i],2,1),(i==pc)and"<- pc"or"",(i==be[2]-wsp)and"<- wsp"or"",(i==be[3]-rsp)and"<- rsp"or"","\n")
	end
	write("--------------","\n")
end










--> OPCODES
local function s(boolean) --> table ; s is short for 'stack'
	return boolean and return_stack or working_stack
end

local usgned_byte = ffi.new("uint8_t[1]")
local usgned_16bt = ffi.new("uint16_t[1]")

local opcodes = setmetatable({
	nil, --0x01
	nil, --0x02
	-- keep is undefined; you can ignore it for this section
	function(r, _2)r=s(r)r.pop() if _2 then r.pop()end end, -- POP 0x03
	function(r, _2)r=s(r)local a,b=r.pop2()if _2 then local c,d=r.pop2()r.push2(b,a)r.push2(d,c)else r.push2(a,b)end end, --SWP 0x04
	function(r, _2)r=s(r)local a,b,c=r.pop3()if _2 then local d,e,f=r.pop3()r.push2(d,c)r.push2(f,e)r.push2(b,a)else r.push3(b,c,a)end end, --ROT 0x05
	function(r, _2)r=s(r)local a=r.pop()if _2 then local b=r.pop()r.push2(b,a)r.push2(b,a)else r.push2(a,a)end end, --DUP 0x06
	function(r, _2)r=s(r)local a,b=r.pop2()if _2 then local c,d=r.pop2()r.push2(d,c)r.push2(b,a)r.push2(d,c) else r.push3(b,a,b)end end, --OVR 0x07

	function(k, r, _2)r=s(r)local a,b=r.pop2()if _2 then local c,d=r.pop2()if k then r.push2(d,c)r.push2(b,a)end r.push(bor(lshift(a,8),b) == bor(lshift(c,8),d) and 0xff or 0)else if k then r.push2(b,a)end r.push((a==b) and 0xff or 0x0)end end, --EQU 0x08
	function(k, r, _2)r=s(r)local a,b=r.pop2()if _2 then local c,d=r.pop2()if k then r.push2(d,c)r.push2(b,a)end r.push(bor(lshift(c,8),d) > bor(lshift(a,8),b) and 0xff or 0)else if k then r.push2(b,a)end r.push(b>a and 0xff or 0)end end, --GTH 0x09
	function(k, r, _2)r=s(r)local a=r.pop()if _2 then local b=r.pop()if k then r.push2(b,a) end pc=(bor(lshift(a,8),b)-1)else if k then r.push(a)end pc=(pc+a-1)end end, --JMP 0x0a FIXED
	function(k, r, _2)r=s(r)local a,b=r.pop2()if _2 then local c=r.pop()pc=(c~=0 and(bor(lshift(a,8),b)-1)or pc)if k then r.push3(c,b,a)end else pc=(b~=0 and(pc+a-1)or pc)if k then r.push2(b,a)end end end, --JNZ 0x0b FIXED
	function(k, r, _2)local R=s(not r)r=s(r)local a=r.pop()if _2 then local b=r.pop()if k then r.push2(b,a)end R.push2(band(pc,0xff),rshift(band(pc,0xff00),8))pc=(bor(lshift(a,8),b)-1)else if k then r.push(a)end R.push2(band(pc,0xff),rshift(band(pc,0xff00),8))pc=(pc+a-1)end end, --JSR 0x0c FIXED
	function(k, r, _2)local R=s(not r)r=s(r)local a=r.pop()if _2 then local b=r.pop()if k then r.push2(b,a)end R.push2(b,a)else if k then r.push(a)end R.push(a)end end, --STH 0x0d
	nil, --0x0e
	nil, --0x0f
	function(k, r, _2)r=s(r)local a = r.pop()if _2 then if k then r.push(a)end r.push2(z.get(a+1),z.get(a))else if k then r.push(a)end r.push(z.get(a))end end, --LDZ 0x10
	function(k, r, _2)r=s(r)local a,b=r.pop2()if _2 then local c=r.pop()if k then r.push3(c,b,a)end z.store(a,b)z.store(a+1,c)else if k then r.push(b,a)end z.store(a,b)end end, --STZ 0x11
	function(k, r, _2)r=s(r)local a=r.pop()if _2 then if k then r.push(a)end r.push2(m[pc+a+1],m[pc+a])else if k then r.push(a)end r.push(m[pc+a])end end, --LDR 0x12
	function(k, r, _2)r=s(r)local a,b=r.pop2()if _2 then local c=r.pop()if k then r.push3(c,b,a)end m[pc+a]=b m[pc+a+1]=c else if k then r.push2(b,a)end m[pc+a]=b end end, --STR 0x13
	function(k, r, _2)r=s(r)local a,b=r.pop2()if _2 then if k then r.push2(b,a)end r.push2(m[bor(lshift(a,8),b)+1],m[bor(lshift(a,8),b)])else if k then r.push2(b,a)end r.push(m[bor(lshift(a,8),b)])end end, --LDA 0x14
	function(k, r, _2)r=s(r)local a,b,c=r.pop3()if _2 then local d=r.pop()if k then r.push2(d,c)r.push2(b,a)end m[bor(lshift(a,8),b)]=c m[bor(lshift(a,8),b)+1]=d else if k then r.push3(c,b,a)end m[bor(lshift(a,8),b)]=c end end, --STA 0x15
	function(k, r, _2)local sp = r r=s(r)local a=r.pop()sp = ((sp and(be[3]-rsp)or(be[2]-wsp))+a)if _2 then if k then r.push(a)end r.push2(m[sp+1],m[sp])else if k then r.push(a)end r.push(m[sp])end end, --PIC 0x16
	function(k, r, _2)local sp = r r=s(r)local a,b=r.pop2()sp = ((sp and(be[3]-rsp)or(be[2]-wsp))+a)if _2 then local c=r.pop()if k then r.push3(c,b,a)end m[sp]=b m[sp+1]=c else if k then r.push2(b,a)end m[sp]=b end end, --PUT 0x17

	function(k, r, _2)r=s(r)local a,b=r.pop2()if _2 then local c,d=r.pop2()if k then r.push2(d,c)r.push2(b,a)end local e = bor(lshift(a,8),b)+bor(lshift(c,8),d)if band(st,1)==1 then e=e+1 end st=((e~=e%0x10000)and bor(st,1)or band(st,0xfe))e = e%0x10000 r.push2(band(e,0xff),rshift(band(e,0xff00),8))else if k then r.push2(b,a)end local c=a+b if band(st,1)==1 then c=c+1 end usgned_byte[0]=c st=((c~=usgned_byte[0])and bor(st,1)or band(st,0xfe))r.push(c)end end, --ADC 0x18
	function(k, r, _2)
		r=s(r)
		local a,b=r.pop2()
		if _2 then 
			local c,d=r.pop2()
			if k then 
				r.push2(d,c)r.push2(b,a)
			end 
			local e = bor(lshift(c,8),d)-bor(lshift(a,8),b)
			if band(st,1)==0 then 
				e=e-1 
			end 
			st=((e==e%0x10000)and bor(st,1)or band(st,0xfe))
			e=e%0x10000 
			r.push2(band(e,0xff),rshift(band(e,0xff00),8))
		else 
			if k then 
				r.push2(b,a)
			end 
			local c=b-a 
			if band(st,1)==0 then
				c=c-1 
			end 
			usgned_byte[0]=c --TODO
			st=((c==usgned_byte[0])and bor(st,1)or band(st,0xfe))
			r.push(c)
		end 
	end, --SBC 0x19
	function(k, r, _2)r=s(r)local a,b=r.pop2()if _2 then local c,d=r.pop2()if k then r.push2(d,c)r.push2(b,a)end local e = (bor(lshift(a,8),b)*bor(lshift(c,8),d))%0x10000 r.push2(band(e,0xff),rshift(band(e,0xff00),8))else if k then r.push2(b,a)end r.push(a*b)end end, --MUL 0x1a
	function(k, r, _2)
		r=s(r)
		local a,b=r.pop2()
		if _2 then local c,d=r.pop2()
			if k then 
				r.push2(d,c)r.push2(b,a)
			end 
			a=bor(lshift(a,8),b) 
			b=bor(lshift(c,8),d) 
			c=b/a 
			d=b%a 
			r.push2(band(c,0xff),rshift(band(c,0xff00),8))
			r.push2(band(d,0xff),rshift(band(d,0xff00),8))
		else 
			if k then r.push2(b,a)end 
			r.push2(b/a,b%a)
		end 
	end, --DVM 0x1b
	function(k, r, _2)r=s(r)local a,b=r.pop2()if _2 then local c,d=r.pop2()if k then r.push2(d,c)r.push2(b,a)end local e = band(bor(lshift(a,8),b),bor(lshift(c,8),d))%0x10000 r.push2(band(e,0xff),rshift(band(e,0xff00),8))else if k then r.push2(b,a)end r.push(band(a,b))end end, --AND 0x1c
	function(k, r, _2)r=s(r)local a,b=r.pop2()if _2 then local c,d=r.pop2()if k then r.push2(d,c)r.push2(b,a)end local e = bor(bor(lshift(a,8),b),bor(lshift(c,8),d))%0x10000 r.push2(band(e,0xff),rshift(band(e,0xff00),8))else if k then r.push2(b,a)end r.push(bor(a,b))end end, --IOR 0x1d
	function(k, r, _2)r=s(r)local a,b=r.pop2()if _2 then local c,d=r.pop2()if k then r.push2(d,c)r.push2(b,a)end local e = xor(bor(lshift(a,8),b),bor(lshift(c,8),d))%0x10000 r.push2(band(e,0xff),rshift(band(e,0xff00),8))else if k then r.push2(b,a)end r.push(xor(a,b))end end, --XOR 0x1e
	function(k, r, _2)r=s(r)local a,b=r.pop2()if _2 then local c=r.pop()if k then r.push3(c,b,a)end c=rshift(lshift(bor(lshift(b,8),c),rshift(band(a,0xf0),4)),band(a,0x0f))%0x10000 r.push2(band(c,0xff),rshift(band(c,0xff00),8))else if k then r.push2(b,a)end b = lshift(b,rshift(band(a,0xf0),4))r.push(rshift(b,band(a,0x0f)))end end, --SFT 0x1f
}, {__index=nop})

local special_opcodes = {
	[0x00]=nop, --NOP 
	[0x20]=function()st=bor(st,1) end, --SEC 
	[0x40]=function()st=band(st,0xfe) end, --CLC
	[0x60]=function()working_stack.push(0)end, --EXT 
	[0x80]=function()pc=pc+1 working_stack.push(m[pc])end, --LIT
	[0xa0]=function()working_stack.push2(m[pc+2],m[pc+1])pc=pc+2 end, --LIT2
	[0xc0]=function()pc=pc+1 return_stack.push (m[pc])end, --LITr
	[0xe0]=function()return_stack.push2 (m[pc+2],m[pc+1])pc=pc+2 end, --LITr2
	[0xef]=function()halt=true end, --useful, but should not be depended on as it is not in the specification
	[0x83]=function()local a,b,c=working_stack.pop(),return_stack.pop2()st=a pc=bor(lshift(b,8),c)end, --RTI
}

local function decode(number) --> number
	local function bool(n1,n2) --> boolean
		return band(n1,n2)>0
	end
	local k,r,_2 = bool(number,0x80), bool(number,0x40), bool(number,0x20)
	;(special_opcodes[number] or opcodes[band(number,0x1f)] or nop)(k,r,_2)
end






do
	local rom_file = io.open(arg[1],"r")
	assert(rom_file, "AVC2: INVALID ROM FILE (WRONG FILE PATH?)")
	local rom = rom_file:read("*a")
	assert(sub(rom,1,4)=="AVC\0", "AVC2: INVALID ROM FILE (MAGIC NUMBER INCORRECT OR MISSING)")
	local block = sub(rom,5)
	local beeoids = ffi.new("uint8_t["..(#rom-4).."]",block..rep("\0", 252-#block))
	for i = 0x0300, 0x0300+#block do
		m[i] = beeoids[i-0x0300]
	end
	rom_file:close()
end


local function save_drive()
	local drive_file = io.open(drive, "w+")
	drive_file:write("AVD\0")
	local block, empty = {}, rep("\0", 256)
	for i = 0,0xffff do
		for j = 0, 255 do
			block[j+1] = char(drive_memory[i][j])
		end
		local block_content = concat(block)
		if block_content ~= empty then
			drive_file:write(char(rshift(band(i,0xff00), 8)), char(band(i,0xff)), block_content)
		end
	end
	drive_file:close()
end


function love.update()
	decode(m[pc])
	pc = (pc + 1)%0x10000
	read(0)
	if halt then 
		if drive then
			save_drive()
		end
		love.event.quit()
	end
end



--TODO:
-- FIX OVERFLOW FOR 16BIT OPERATIONS
--less pressing:
-- REDO PAGE MOVING SO IT'S LESS NAÏVE (also wow capital ï looks really funny)
-- CLEAN UP THE COMMENTS (EW)
-- REMOVE/COMMENT UNNECESSARY ERRORS/ASSERTS



--[[

MISCELLANEOUS

avc2 is big-endian
values are unsigned by default. signed use 2's complement.




FOUR REGISTERS

--> TWO STACKS, MUST GROW DOWNWARDS
wsp: Working Stack Pointer, 0x0100-0x01ff
rsp: Return  Stack Pointer, 0x0200-0x02ff

--> USED FOR CARRY/INVERSE BORROW FLAG (bit 0)
st:  STatus

--> [no additional comments]
pc:  Program Counter




MEMORY MAP

0x0000-0x00ff: zero page
0x0100-0x01ff: wsp (Working Stack Pointer)
0x0200-0x02ff: rsp (Return  Stack Pointer)
0x0300-0xfeff: program start point
0xff00-0xffff: memory-mapped device I/O




INSTRUCTIONS

--> THREE 1-BIT FLAGS, ONE 5-BIT OPCODE
kr2ooooo

k: [k]eeps values on stack. (i.e. (n1 n2 -- n1 n2 n1+n2))
r: operates on [r]eturn stack directly, or swaps if it operates on both.
2: uses double-width (8*[2], 16-bit) values from stack.


--> STACK PRIMITIVES [0x03-0x07] [keep is undefined]
0x03 POP (a b    -- a    ) * POPk (0x83) is used instead for RTI
0x04 SWP (a b    -- b a  )
0x05 ROT (a b c  -- b a c)
0x06 DUP (a      -- a a  )
0x07 OVR (a b    -- a b a)

--> LOGIC AND JUMPS  [0x08-0x0d]
0x08 EQU (a b    -- a==b ) * true: 0xff, false: 0x00
0x09 GTH (a b    -- a>b  ) * both must be signed
0x0a JMP (addr   --      ) * JMP2 uses 16-bit ABSOLUTE address; normal uses RELATIVE 8-bit address
0x0b JNZ (8 addr --      ) * same as JMP, but takes an 8-bit (specifically) value and jumps if not 0, or continues
0x0c JSR (addr   -- r[pc]) * same as JMP, but pushes pc to retstack before jumping
0x0d STH (a      --      ) * moves to return stack

--> MEMORY ACCESSES  [0x10-0x17]
0x10 LDZ (8      -- z[8] ) * push value at 8 in the zero-page
0x11 STZ (a 8    --      ) * stores   a at 8 in the zero-page
0x12 LDR (8s     --@pc+8s) * push value at pc+8s
0x13 STR (a 8s   -- *    ) * store    a at pc+8s
0x14 LDA (16     --@16   ) * push value at absolute 16-bit address
0x15 STA (a 16   --      ) * store    a at absolute 16-bit address
0x16 PIC (8      --@8+wsp) * push value at wsp+8
0x17 PUT (a 8    --      ) * store    a at wsp+8

--> ARITHMETIC       [0x18-0x1f]
0x18 ADC (a b    -- a+b  ) * add 1 if carry flag is     set; set   carry flag if  overflow; otherwise unset.
0x19 SBC (a b    -- b-a  ) * sub 1 if carry flag is NOT set; unset carry flag if underflow; otherwise   set. 
0x1a MUL (a b    -- a*b  ) * 
0x1b DVM (a b    -- *    ) * push b/a, then b%a
0x1c AND (a b    -- a&b  ) * 
0x1d IOR (a b    -- a|b  ) * 
0x1e XOR (a b    -- a^b  ) * 
0x1f SFT (a b    -- *    ) * (b<<a_upper)>>a_lower

--> ODDS AND ENDS [NO MODES EXCEPT LIT]
0x00 NOP (       --      ) * does nothing
0x20 SEC (       --      ) * sets   carry flag
0x40 CLC (       --      ) * clears carry flag
0x60 EXT (       -- $0   ) * pushes 0 to the stack (will later be used for something else)
0x80 LIT (       --@pc+$1) * pushes next byte (or 16-bit words if [2]), then skips over the pushed value 
0x83 RTI (16 a   --      ) * ST set to a, JMP2 16




DEVICE I/O

--> EVERY DEVICE HAS 16 BYTES OF I/O SPACE
--> THE FIRST BYTE MUST BE THE DEVICE ID IN RANGE [1,240 (0xF0)] WHICH CORRESPONDS TO DEVICE TYPE.
--> DEVICES MAY USE MULTI-BYTE PORTS. DEVICES MAY MODIFY THEIR INTERNAL STATE ON READ. UNUSED CELLS MUST RETURN $0.


DEVICES

--> SYSTEM DEVICE [0xff00-0xff0f]
0 DEVID:  returns $1
1 WAIT:   suspend cpu for (written) ms
2 RANDOM: returns random(0≤x<256)
3-7:      [unused]
8 STDIN:  when read,       returns byte from the terminal input, or 0x00 if no bytes are present in the buffer
9 STDOUT: when written to, sends byte to stdout terminal
a STDERR: when written to, sends byte to stderr terminal
b BUFLEN: when read,       returns size of the input buffer, or 0xff if greater than 0xff
f HALT:   when written to, immediately halt the CPU

--> DRIVE DEVICE  [0xff10-0xff1f]
* SAVE TO FILE UPON EXIT
* STARTS WITH 0x(41 56 44 00), REST IS BLOCKS OF 258 BYTES (2 FOR BLOCK NUMBER, 256 FOR BLOCK CONTENTS)
* ANY BLOCKS NOT GIVEN IN THE ARCHIVE ARE ASSUMED EMPTY

0 DEVID:  returns $2
1:        [unused]
2 BLKHB:  when written to, sets high byte of block address
3 BLKLB:  when written to, sets low  byte of block address
4 PAGE:   set the page of memory to use
5-7:      [unused]
8 READ:   move the specified block of the drive into memory, at the specified page
9 WRITE:  move the specified page of memory into the drive, at the specified block




CONVENTIONS

--> ROM FORMAT
* MUST START WITH 0x(41 56 43 00)
* MAGIC NUMBER
* THE REST IS PROGRAM DATA, AND IS LOADED AT THE PROGRAM START POINT

--> JUMPING
* PC IS INCREMENTED BY 1 AT THE END OF EACH EXECUTION CYCLE, SO YOU WILL WANT TO JUMP TO ADDRESS N-1 TO GET TO ADDRESS N

--> DATA STRUCTURES
* BOOLEANS ARE 0x0 FOR FALSE AND NONZERO FOR TRUE. equ AND gth RETURN 0xff FOR TRUE. STRINGS SHOULD BE STORED ON THE HEAP? AND REFERRED TO WITH A FAT POINTER ON THE STACK. NULL-TERMINATED STRINGS SHOULD NOT BE USED.
]]
