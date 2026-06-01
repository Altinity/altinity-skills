# Skills Build System (LOCAL builds only)
# Creates zip files for all skill directories (directories containing SKILL.md).
# Output lands in releases/, which is gitignored. CI does NOT use this Makefile:
# the GitHub workflows build their own zips into dist/ and publish via Releases.

SKILLS_DIR := $(CURDIR)
BUILD_DIR := $(SKILLS_DIR)/releases
SKILL_DIRS := $(shell \
    find altinity-expert-clickhouse/skills -maxdepth 2 -name "SKILL.md" ! -path "*/.system/*" -exec dirname {} \; | sort; \
    find . -mindepth 2 -maxdepth 2 -name "SKILL.md" ! -path "*/altinity-expert-clickhouse/*" ! -path "*/.git/*" ! -path "*/.github/*" -exec dirname {} \; | sed 's|^\./||' | sort)
SKILL_ZIPS := $(foreach dir,$(SKILL_DIRS),$(BUILD_DIR)/$(notdir $(dir)).zip)

.PHONY: all clean list help

all: $(BUILD_DIR) $(SKILL_ZIPS)
	@echo "Built $(words $(SKILL_ZIPS)) skill packages in $(BUILD_DIR)/"

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

define ZIP_template
$(BUILD_DIR)/$(notdir $(1)).zip: $(shell find $(1) -type f) | $(BUILD_DIR)
	@echo "Packaging $(notdir $(1))..."
	@rm -f $(BUILD_DIR)/$(notdir $(1)).zip
	@cd $(1) && zip -rq $(BUILD_DIR)/$(notdir $(1)).zip . -x "*.DS_Store" -x "*__MACOSX*" -x "*.git*" -x "*__pycache__*" -x "*.pyc"
endef

$(foreach dir,$(SKILL_DIRS),$(eval $(call ZIP_template,$(dir))))

clean:
	@echo "Cleaning build directory..."
	@rm -rf $(BUILD_DIR)

list:
	@echo "Skills found:"
	@$(foreach dir,$(SKILL_DIRS),echo "  - $(notdir $(dir)) ($(dir))";)

help:
	@echo "Skills Build System"
	@echo ""
	@echo "Usage:"
	@echo "  make          Build all skill zip files"
	@echo "  make all      Same as 'make'"
	@echo "  make clean    Remove all built zip files"
	@echo "  make list     List all detected skills"
	@echo "  make help     Show this help"
	@echo ""
	@echo "Output: releases/<skill-name>.zip"
