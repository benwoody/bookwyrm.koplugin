PLUGIN_NAME = bookwyrm.koplugin
RUNTIME_FILES = _meta.lua main.lua bookwyrmclient.lua localbooks.lua

.PHONY: test release clean

test:
	busted --verbose

release: clean
	mkdir -p build/$(PLUGIN_NAME)
	cp $(RUNTIME_FILES) build/$(PLUGIN_NAME)/
	cd build && zip -r ../$(PLUGIN_NAME).zip $(PLUGIN_NAME)/
	rm -rf build
	@echo "Created $(PLUGIN_NAME).zip"

clean:
	rm -rf build $(PLUGIN_NAME).zip
