# Altinity Expert Kubernetes - Skills Build System
# Builds zips, links into ~/.claude/skills, and lists skills in this domain.
# Scope: altinity-expert-kubernetes/skills/*/SKILL.md only.

DOMAIN_DIR := $(shell pwd)
BUILD_DIR  := $(DOMAIN_DIR)/releases
SKILL_DIRS := $(shell find skills -maxdepth 2 -name "SKILL.md" ! -path "*/.system/*" -exec dirname {} \; 2>/dev/null | sort)
SKILL_ZIPS := $(foreach dir,$(SKILL_DIRS),$(BUILD_DIR)/$(notdir $(dir)).zip)

CLAUDE_SKILLS_DIR ?= $(HOME)/.claude/skills

.PHONY: all clean list help link unlink relink links

all: $(BUILD_DIR) $(SKILL_ZIPS)
	@echo "Built $(words $(SKILL_ZIPS)) skill packages in $(BUILD_DIR)/"

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

define ZIP_template
$(BUILD_DIR)/$(notdir $(1)).zip: $(1)/SKILL.md
	@echo "Packaging $(notdir $(1))..."
	@cd $(1) && zip -r $(BUILD_DIR)/$(notdir $(1)).zip . -x "*.DS_Store" -x "*__MACOSX*" -x "*.git*" -x "*__pycache__*" -x "*.pyc"
endef

$(foreach dir,$(SKILL_DIRS),$(eval $(call ZIP_template,$(dir))))

clean:
	@echo "Cleaning build directory..."
	@rm -rf $(BUILD_DIR)

list:
	@echo "Expert Kubernetes skills found:"
	@$(foreach dir,$(SKILL_DIRS),echo "  - $(notdir $(dir)) ($(dir))";)

link: | $(CLAUDE_SKILLS_DIR)
	@$(foreach dir,$(SKILL_DIRS), \
	    target="$(CLAUDE_SKILLS_DIR)/$(notdir $(dir))"; \
	    src="$(DOMAIN_DIR)/$(dir)"; \
	    if [ -L "$$target" ]; then \
	        cur=$$(readlink "$$target"); \
	        if [ "$$cur" = "$$src" ]; then \
	            echo "ok       $(notdir $(dir))"; \
	        else \
	            echo "CONFLICT $(notdir $(dir)) -> $$cur (run 'make relink' to replace)"; \
	        fi; \
	    elif [ -e "$$target" ]; then \
	        echo "SKIP     $(notdir $(dir)) (real dir/file exists, not touching)"; \
	    else \
	        ln -s "$$src" "$$target" && echo "linked   $(notdir $(dir))"; \
	    fi;)

unlink:
	@$(foreach dir,$(SKILL_DIRS), \
	    target="$(CLAUDE_SKILLS_DIR)/$(notdir $(dir))"; \
	    if [ -L "$$target" ]; then \
	        rm "$$target" && echo "unlinked $(notdir $(dir))"; \
	    fi;)

relink: unlink link

links:
	@echo "Expert Kubernetes skills in $(CLAUDE_SKILLS_DIR):"
	@$(foreach dir,$(SKILL_DIRS), \
	    target="$(CLAUDE_SKILLS_DIR)/$(notdir $(dir))"; \
	    if [ -L "$$target" ]; then \
	        echo "  $(notdir $(dir)) -> $$(readlink $$target)"; \
	    else \
	        echo "  $(notdir $(dir)) (not linked)"; \
	    fi;)

$(CLAUDE_SKILLS_DIR):
	@mkdir -p $(CLAUDE_SKILLS_DIR)

help:
	@echo "Altinity Expert Kubernetes - Skills Build System"
	@echo ""
	@echo "Usage:"
	@echo "  make          Build all skill zip files"
	@echo "  make all      Same as 'make'"
	@echo "  make clean    Remove all built zip files"
	@echo "  make list     List all detected expert-kubernetes skills"
	@echo "  make link     Symlink all expert-kubernetes skills into ~/.claude/skills"
	@echo "  make unlink   Remove those symlinks (leaves real dirs alone)"
	@echo "  make relink   unlink + link"
	@echo "  make links    Show current link state"
	@echo "  make help     Show this help"
	@echo ""
	@echo "Output: releases/<skill-name>.zip"
	@echo ""
	@echo "Override link destination: make link CLAUDE_SKILLS_DIR=./.claude/skills"
