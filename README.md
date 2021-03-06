# avc2.lua
avc2.lua is an [avc2](https://github.com/ambyshframber/avc2) emulator, written in luajit, with tweaks for löve2d.
`avc2.love` and its sources are located in the `love` folder.
```
NAME
	avc2.lua - a luajit avc2 emulator

SYNOPSIS
	luajit avc2.lua ROM.avcr [DRIVE.avd]
	luajit avc2.lua [-h|-?|--help]

	love avc2.love ROM.avcr [DRIVE.avd]
	love avc2.love [-h|-?|--help]

DESCRIPTION
	An avc2 (https://github.com/ambyshframber/avc2) emulator, written in luajit. avc2.love has tweaks to make it work with löve2d.
	There are some things that should be noted for this emulator:
	• ALL operations can accept signed values (i.e. one can JMP backwards by using a negative value). This may be changed in the future.
	• ADC and SBC are probably broken slightly.
	• As it turns out, reading IO in a non-blocking fashion is far harder than it should be, and is currently not implemented in Windows.
```
