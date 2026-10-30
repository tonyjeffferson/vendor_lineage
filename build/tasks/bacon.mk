# Copyright (C) 2017 Unlegacy-Android
# Copyright (C) 2017,2020 The LineageOS Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# -----------------------------------------------------------------
# Lineage OTA update package

LINEAGE_TARGET_PACKAGE := $(PRODUCT_OUT)/$(LINEAGE_VERSION).zip
OTA_TARGET_FILES_DIR := $(PRODUCT_OUT)/.ota_target_files
OTA_TARGET_FILES_BASE := $(OTA_TARGET_FILES_DIR)/base-target_files.zip
OTA_TARGET_FILES_TARGET := $(OTA_TARGET_FILES_DIR)/target-target_files.zip

$(LINEAGE_TARGET_PACKAGE): $(INTERNAL_OTA_PACKAGE_TARGET) $(BUILT_TARGET_FILES_PACKAGE)
	$(hide) mv -f $(INTERNAL_OTA_PACKAGE_TARGET) $(LINEAGE_TARGET_PACKAGE)
	$(hide) ./vendor/lineage/build/tools/createjson.sh $(TARGET_DEVICE) $(PRODUCT_OUT) $(LINEAGE_VERSION).zip
	$(hide) mkdir -p $(OTA_TARGET_FILES_DIR)
	$(hide) cp -f $(BUILT_TARGET_FILES_PACKAGE) $(OTA_TARGET_FILES_BASE).tmp && mv -f $(OTA_TARGET_FILES_BASE).tmp $(OTA_TARGET_FILES_BASE)
	$(hide) rm -rf $(call intermediates-dir-for,PACKAGING,target_files)
	$(hide) ./vendor/lineage/build/tasks/ascii_output.sh
	echo -e "\n${CL_BLD}${CL_GRN}================================================================================${CL_RST}" >&2
	echo -e "${CL_BLD}${CL_CYN}                🎊✨ BUILD COMPLETED SUCCESSFULLY! ✨🎊${CL_RST}" >&2
	echo -e "${CL_BLD}${CL_GRN}================================================================================${CL_RST}" >&2
	echo -e "" >&2
	echo -e "${CL_BLD}${CL_WHT}📦 Package:${CL_RST}  ${CL_BLD}${CL_YEL}$(notdir $(LINEAGE_TARGET_PACKAGE))${CL_RST}" >&2
	echo -e "${CL_BLD}${CL_WHT}📍 Location:${CL_RST} ${CL_BLD}${CL_BLU}$(dir $(LINEAGE_TARGET_PACKAGE))${CL_RST}" >&2
	echo -e "${CL_BLD}${CL_WHT}📱 Device:${CL_RST}   ${CL_BLD}${CL_CYN}$(TARGET_DEVICE) [$(TARGET_BUILD_VARIANT)]${CL_RST}" >&2
	echo -e "${CL_BLD}${CL_WHT}💾 Size:${CL_RST}     ${CL_BLD}${CL_YEL}$(shell du -h $(LINEAGE_TARGET_PACKAGE) | cut -f1)${CL_RST}" >&2
	echo -e "${CL_BLD}${CL_WHT}⏱️ Finished At:${CL_RST} ${CL_BLD}${CL_MAG}$(shell date '+%Y-%m-%d %H:%M:%S')${CL_RST}" >&2
	echo -e "" >&2
	echo -e "${CL_BLD}${CL_RED}                ❤️ Thank you for building Lunaris-AOSP! ❤️${CL_RST}" >&2
	echo -e "" >&2
	echo -e "${CL_BLD}${CL_GRN}=============================================================================${CL_RST}" >&2
	echo -e "${CL_BLD}${CL_YEL}	🎉 Your ROM is hot out of the oven & ready to flash! 🎉${CL_RST}" >&2
	echo -e "${CL_BLD}${CL_GRN}=============================================================================${CL_RST}" >&2
	echo -e "" >&2

.PHONY: bacon
bacon: $(LINEAGE_TARGET_PACKAGE) $(DEFAULT_GOAL)

.PHONY: lunaris
lunaris: bacon

ifneq ($(filter ota,$(MAKECMDGOALS)),)
ifeq ($(wildcard $(OTA_TARGET_FILES_BASE)),)
$(error No base target_files archive found at $(OTA_TARGET_FILES_BASE). Run 'm bacon' or 'm lunaris' first)
endif
endif

.PHONY: ota
ota: $(OTA_FROM_TARGET_FILES) $(BUILT_TARGET_FILES_PACKAGE)
	$(hide) mkdir -p $(OTA_TARGET_FILES_DIR)
	$(hide) cp -f $(BUILT_TARGET_FILES_PACKAGE) $(OTA_TARGET_FILES_TARGET).tmp && mv -f $(OTA_TARGET_FILES_TARGET).tmp $(OTA_TARGET_FILES_TARGET)
	$(hide) trap 'rm -f $(OTA_TARGET_FILES_TARGET) $(OTA_TARGET_FILES_TARGET).tmp; rm -rf $(call intermediates-dir-for,PACKAGING,target_files)' EXIT; python3 vendor/lineage/build/tools/createincrementalota.py \
		--build-top $(abspath .) \
		--product-out $(PRODUCT_OUT) \
		--device $(TARGET_DEVICE) \
		--version $(LINEAGE_VERSION) \
		--ota-tool $(OTA_FROM_TARGET_FILES) \
		--source-target-files $(OTA_TARGET_FILES_BASE) \
		--target-target-files $(OTA_TARGET_FILES_TARGET) && \
		mv -f $(OTA_TARGET_FILES_TARGET) $(OTA_TARGET_FILES_BASE)
