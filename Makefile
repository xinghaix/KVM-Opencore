KEXTS= \
	EFI/OC/Kexts/Lilu.kext \
	EFI/OC/Kexts/WhateverGreen.kext \
	EFI/OC/Kexts/AppleALC.kext \
	EFI/OC/Kexts/VirtualSMC.kext \
	EFI/OC/Kexts/BrcmNonPatchRAM2.kext \
	EFI/OC/Kexts/BrcmPatchRAM2.kext \
	EFI/OC/Kexts/BrcmPatchRAM3.kext \
	EFI/OC/Kexts/BrcmBluetoothInjector.kext \
	EFI/OC/Kexts/BlueToolFixup.kext \
	EFI/OC/Kexts/BrcmFirmwareData.kext \
	EFI/OC/Kexts/CryptexFixup.kext

DRIVERS= \
	EFI/OC/Drivers/OpenHfsPlus.efi \
	EFI/OC/Drivers/OpenRuntime.efi \
	EFI/OC/Drivers/OpenCanopy.efi \
	EFI/OC/Drivers/OpenPartitionDxe.efi \
	EFI/OC/Drivers/ResetNvramEntry.efi \
	EFI/OC/Drivers/ToggleSipEntry.efi

TOOLS = \
	EFI/OC/Tools/Shell.efi \
	EFI/OC/Tools/ResetSystem.efi

MISC= \
	EFI/BOOT/BOOTx64.efi \
	EFI/OC/OpenCore.efi \
	EFI/OC/Resources

EFI_FILES=$(KEXTS) $(DRIVERS) $(TOOLS) $(MISC) EFI/OC/config.plist

SUBMODULES = \
	src/AppleALC/README.md \
	src/Lilu/README.md \
	src/WhateverGreen/README.md \
	src/OpenCorePkg/README.md \
	src/VirtualSMC/README.md \
	src/OcBinaryData/Resources \
	src/MacKernelSDK/README.md \
	src/CryptexFixup/README.md

# Set me to include the version number in the packaged filenames
RELEASE_VERSION ?= master

# Either DEBUG or RELEASE
OPENCORE_MODE=RELEASE

OPENCORE_UDK_BUILD_DIR=src/OpenCorePkg/UDK/Build/OpenCorePkg/$(OPENCORE_MODE)_XCODE5/X64

.DUMMY : all very-clean clean dist

# Avoid submodules having their own directories as a dependency by moving that dependency to the top here:
# (avoids rebuilding deps after they touch their directories during build)
all : $(SUBMODULES) $(EFI_FILES)

dist : $(SUBMODULES) OpenCore-$(RELEASE_VERSION).dmg.gz OpenCoreEFIFolder-$(RELEASE_VERSION).zip OpenCore-$(RELEASE_VERSION).iso.gz

# Assemble a release from official acidanthera binaries (used by GitHub Actions).
ci-dist :
	./scripts/package-release.sh --version $(RELEASE_VERSION)

# Create OpenCore disk image:

OpenCore-$(RELEASE_VERSION).dmg : Makefile $(EFI_FILES)
	rm -f $@
	hdiutil create -layout GPTSPUD -partitionType EFI -fs "FAT32" -megabytes 150 -volname EFI $@
	mkdir -p OpenCore-Image
	DEV_NAME=$$(hdiutil attach -nomount -plist $@ | xpath -e "/plist/dict/array/dict/key[text()='content-hint']/following-sibling::string[1][text()='EFI']/../key[text()='dev-entry']/following-sibling::string[1]/text()" 2> /dev/null) && \
		mount -tmsdos "$$DEV_NAME" OpenCore-Image
	find EFI -type f -name ".DS_Store" -delete
	cp -a EFI OpenCore-Image/
	hdiutil detach -force OpenCore-Image

# Not actually an ISO, but useful for making it usable in Proxmox's ISO picker
OpenCore-$(RELEASE_VERSION).iso : OpenCore-$(RELEASE_VERSION).dmg
	cp $< $@

OpenCoreEFIFolder-$(RELEASE_VERSION).zip : Makefile $(EFI_FILES)
	rm -f $@
	find EFI -type f -name ".DS_Store" -delete
	zip -X -r $@ EFI

%.gz : %
	gzip -f --keep $<

# AppleALC:

EFI/OC/Kexts/AppleALC.kext : src/AppleALC/build/Release/AppleALC.kext
	cp -a $< $@

src/AppleALC/build/Release/AppleALC.kext : src/AppleALC src/AppleALC/Lilu.kext src/AppleALC/MacKernelSDK
	cd src/AppleALC && xcodebuild -configuration $(OPENCORE_MODE)

# WhateverGreen:

EFI/OC/Kexts/WhateverGreen.kext : src/WhateverGreen/build/Release/WhateverGreen.kext
	cp -a $< $@

src/WhateverGreen/build/Release/WhateverGreen.kext : src/WhateverGreen src/WhateverGreen/Lilu.kext src/WhateverGreen/MacKernelSDK
	cd src/WhateverGreen && xcodebuild -configuration $(OPENCORE_MODE)

# VirtualSMC:

EFI/OC/Kexts/VirtualSMC.kext : src/VirtualSMC/build/Release/VirtualSMC.kext
	cp -a $< $@

src/VirtualSMC/build/Release/VirtualSMC.kext : src/VirtualSMC/Lilu.kext src/VirtualSMC/MacKernelSDK
	cd src/VirtualSMC && xcodebuild -configuration $(OPENCORE_MODE)
	touch $@

# BrcmPatchRAM:

src/BrcmPatchRAM/build/Products/Release/BlueToolFixup.kext \
src/BrcmPatchRAM/build/Products/Release/BrcmNonPatchRAM.kext \
src/BrcmPatchRAM/build/Products/Release/BrcmNonPatchRAM2.kext \
src/BrcmPatchRAM/build/Products/Release/BrcmPatchRAM2.kext \
src/BrcmPatchRAM/build/Products/Release/BrcmPatchRAM3.kext \
src/BrcmPatchRAM/build/Products/Release/BrcmFirmwareData.kext \
src/BrcmPatchRAM/build/Products/Release/BrcmBluetoothInjector.kext : src/BrcmPatchRAM/Lilu.kext src/BrcmPatchRAM/MacKernelSDK
	# Needs macOS 11 SDK rather than 12.0 to meet deployment target, e.g. from https://github.com/phracker/MacOSX-SDKs and:
	# export SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX11.3.sdk
	cd src/BrcmPatchRAM && xcodebuild -configuration $(OPENCORE_MODE)
	touch $@

EFI/OC/Kexts/BrcmNonPatchRAM.kext : src/BrcmPatchRAM/build/Products/Release/BrcmNonPatchRAM.kext
	cp -a $< $@

EFI/OC/Kexts/BrcmNonPatchRAM2.kext : src/BrcmPatchRAM/build/Products/Release/BrcmNonPatchRAM2.kext
	cp -a $< $@

EFI/OC/Kexts/BrcmPatchRAM2.kext : src/BrcmPatchRAM/build/Products/Release/BrcmPatchRAM2.kext
	cp -a $< $@

EFI/OC/Kexts/BrcmPatchRAM3.kext : src/BrcmPatchRAM/build/Products/Release/BrcmPatchRAM3.kext
	cp -a $< $@

EFI/OC/Kexts/BrcmBluetoothInjector.kext : src/BrcmPatchRAM/build/Products/Release/BrcmBluetoothInjector.kext
	cp -a $< $@
	
EFI/OC/Kexts/BlueToolFixup.kext : src/BrcmPatchRAM/build/Products/Release/BlueToolFixup.kext
	cp -a $< $@

EFI/OC/Kexts/BrcmFirmwareData.kext : src/BrcmPatchRAM/build/Products/Release/BrcmFirmwareData.kext
	cp -a $< $@

# CryptexFixup:

EFI/OC/Kexts/CryptexFixup.kext : src/CryptexFixup/build/Release/CryptexFixup.kext
	cp -a $< $@

src/CryptexFixup/build/Release/CryptexFixup.kext : src/CryptexFixup src/CryptexFixup/Lilu.kext src/CryptexFixup/MacKernelSDK
	cd src/CryptexFixup && xcodebuild -configuration $(OPENCORE_MODE)

# Lilu:

EFI/OC/Kexts/Lilu.kext : src/Lilu/build/Release/Lilu.kext
	cp -a $< $@

src/Lilu/build/Release/Lilu.kext src/Lilu/build/Debug/Lilu.kext : src/Lilu/MacKernelSDK 
	cd src/Lilu && xcodebuild -configuration Debug
	cd src/Lilu && xcodebuild -configuration Release

src/WhateverGreen/Lilu.kext \
src/AppleALC/Lilu.kext \
src/VirtualSMC/Lilu.kext \
src/BrcmPatchRAM/Lilu.kext \
src/CryptexFixup/Lilu.kext : src/Lilu/build/Debug/Lilu.kext
	ln -s ../Lilu/build/Debug/Lilu.kext $@

# MacKernelSDK:

src/Lilu/MacKernelSDK \
src/WhateverGreen/MacKernelSDK \
src/AppleALC/MacKernelSDK \
src/VirtualSMC/MacKernelSDK \
src/BrcmPatchRAM/MacKernelSDK \
src/CryptexFixup/MacKernelSDK : src/MacKernelSDK
	ln -s ../MacKernelSDK $@
	
# OpenCore:

EFI/OC/OpenCore.efi : $(OPENCORE_UDK_BUILD_DIR)/OpenCore.efi
	cp -a $< $@

EFI/OC/Drivers/OpenRuntime.efi EFI/OC/Drivers/OpenHfsPlus.efi EFI/OC/Drivers/OpenPartitionDxe.efi \
EFI/OC/Drivers/ResetNvramEntry.efi EFI/OC/Drivers/ToggleSipEntry.efi \
 : $(OPENCORE_UDK_BUILD_DIR)/OpenRuntime.efi $(OPENCORE_UDK_BUILD_DIR)/OpenHfsPlus.efi $(OPENCORE_UDK_BUILD_DIR)/OpenPartitionDxe.efi $(OPENCORE_UDK_BUILD_DIR)/ResetNvramEntry.efi $(OPENCORE_UDK_BUILD_DIR)/ToggleSipEntry.efi
	mkdir -p EFI/OC/Drivers
	cp -a $? EFI/OC/Drivers/

EFI/BOOT/BOOTx64.efi : $(OPENCORE_UDK_BUILD_DIR)/Bootstrap.efi
	mkdir -p EFI/BOOT
	cp -a $< $@

$(OPENCORE_UDK_BUILD_DIR)/OpenCore.efi $(OPENCORE_UDK_BUILD_DIR)/OpenRuntime.efi \
$(OPENCORE_UDK_BUILD_DIR)/Bootstrap.efi $(OPENCORE_UDK_BUILD_DIR)/Shell.efi \
$(OPENCORE_UDK_BUILD_DIR)/ResetSystem.efi $(OPENCORE_UDK_BUILD_DIR)/OpenCanopy.efi \
$(OPENCORE_UDK_BUILD_DIR)/OpenHfsPlus.efi $(OPENCORE_UDK_BUILD_DIR)/OpenPartitionDxe.efi \
 :
	cd src/OpenCorePkg && ARCHS=X64 ./build_oc.tool --skip-package $(OPENCORE_MODE)

# Tools

EFI/OC/Tools/Shell.efi : $(OPENCORE_UDK_BUILD_DIR)/Shell.efi
	mkdir -p EFI/OC/Tools
	cp -a $< $@

EFI/OC/Tools/ResetSystem.efi : $(OPENCORE_UDK_BUILD_DIR)/ResetSystem.efi
	mkdir -p EFI/OC/Tools
	cp -a $< $@

EFI/OC/Drivers/OpenCanopy.efi : $(OPENCORE_UDK_BUILD_DIR)/OpenCanopy.efi
	mkdir -p EFI/OC/Drivers
	cp -a $< $@

EFI/OC/Resources : src/OcBinaryData/Resources
	cp -a $< EFI/OC/

# Fetch submodules:

$(SUBMODULES) :
	git submodule update --init

EFI/BOOT/ EFI/OC/Drivers/ EFI/OC/Tools/ :
	mkdir $@

# Also check out the UDK and its dependencies from scratch again - useful when build errors occur in UDK
very-clean : clean
	rm -rf src/OpenCorePkg/UDK

clean :
	rm -rf OpenCore-Image/ src/Lilu/build src/WhateverGreen/build src/OpenCorePkg/UDK/Build src/BrcmPatchRAM/build \
		src/AppleALC/build src/CryptexFixup/build $(KEXTS) $(DRIVERS) $(TOOLS) $(MISC)
	rm -f OpenCore-${RELEASE_VERSION}.dmg* OpenCore-${RELEASE_VERSION}.iso* OpenCoreEFIFolder-${RELEASE_VERSION}.zip 