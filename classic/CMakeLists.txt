cmake_minimum_required(VERSION 3.13)
project(TheGardenClassic C)

# Mac OS 9 is the target, so PowerPC is the native one; the same sources build
# for 68k, which is how they are checked while the PowerPC toolchain is being
# built.  Nothing here is architecture-specific.
if(CMAKE_SYSTEM_PROCESSOR MATCHES "m68k")
    add_compile_options(-mcpu=68020 -msoft-float -Wno-multichar)
    add_link_options(-mcpu=68020 -msoft-float)
endif()

add_application(GardenNet
    src/gdtcp.c
    src/gddns.c
    src/gdparse.c
    src/gdhttp.c
    src/gdmain.c
    TYPE APPL
    CREATOR "Gdn ")
