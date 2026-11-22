# Сборка «Мунина» (рабочее имя — Мнемозина) одной командой: make app
APP      := build/Мунин.app
SIGN_ID  ?= Mnemosyne Local Signing
CONFIG   ?= release
UV_VER   := 0.11.2
UV_BIN   := vendor/uv-$(UV_VER)/uv

.PHONY: app run install test cert clean selftest icon demo dmg

# uv внутри .app ставит Python и mlx-whisper у друзей. Качается один раз, сверяется по sha256.
$(UV_BIN):
	mkdir -p vendor/uv-$(UV_VER)
	curl -fsSL -o vendor/uv.tar.gz https://github.com/astral-sh/uv/releases/download/$(UV_VER)/uv-aarch64-apple-darwin.tar.gz
	curl -fsSL -o vendor/uv.tar.gz.sha256 https://github.com/astral-sh/uv/releases/download/$(UV_VER)/uv-aarch64-apple-darwin.tar.gz.sha256
	cd vendor && shasum -a 256 -c uv.tar.gz.sha256 2>/dev/null || (echo "$$(cut -d' ' -f1 uv.tar.gz.sha256)  uv.tar.gz" | shasum -a 256 -c -)
	tar -xzf vendor/uv.tar.gz -C vendor/uv-$(UV_VER) --strip-components=1
	rm vendor/uv.tar.gz vendor/uv.tar.gz.sha256

app: $(UV_BIN)
	swift build -c $(CONFIG)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/$(CONFIG)/Mnemosyne $(APP)/Contents/MacOS/Mnemosyne
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/mermaid.min.js $(APP)/Contents/Resources/mermaid.min.js
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp -R Skills $(APP)/Contents/Resources/Skills
	cp LICENSE THIRD_PARTY_NOTICES.md $(APP)/Contents/Resources/
	cp Resources/whisper_runner.py $(APP)/Contents/Resources/whisper_runner.py
	cp $(UV_BIN) $(APP)/Contents/MacOS/uv
	@if security find-certificate -c "$(SIGN_ID)" >/dev/null 2>&1; then \
		codesign --force --sign "$(SIGN_ID)" --identifier local.mnemosyne.uv $(APP)/Contents/MacOS/uv; \
		codesign --force --sign "$(SIGN_ID)" --identifier local.mnemosyne.app $(APP); \
	else \
		echo "Нет сертификата «$(SIGN_ID)», подписываю ad-hoc (разрешения сбросятся после пересборки). Запустите make cert"; \
		codesign --force --sign - $(APP)/Contents/MacOS/uv; \
		codesign --force --sign - --identifier local.mnemosyne.app $(APP); \
	fi
	@echo "Готово: $(APP)"

run: app
	-pkill -x Mnemosyne
	open $(APP)

# Ставит в ~/Applications, чтобы запускать из Spotlight и добавить в автозапуск.
install: app
	-pkill -x Mnemosyne
	mkdir -p $(HOME)/Applications
	rm -rf $(HOME)/Applications/Mnemosyne.app $(HOME)/Applications/Мунин.app
	cp -R $(APP) $(HOME)/Applications/Мунин.app
	open $(HOME)/Applications/Мунин.app

test:
	swift test

cert:
	./scripts/make-cert.sh

clean:
	rm -rf .build build

# Смоук-тест записи: 8 секунд в папку build/selftest, во время записи играет системный звук.
selftest: app
	rm -rf build/selftest && mkdir -p build/selftest
	( for i in 1 2 3 4 5 6; do afplay /System/Library/Sounds/Submarine.aiff; done ) &
	open --env MNEMOSYNE_ROOT=$(CURDIR)/build/selftest --env MNEMOSYNE_SELFTEST=8 $(APP)
	@for i in $$(seq 1 40); do [ -f build/selftest/selftest.txt ] && break; sleep 1; done
	@cat build/selftest/selftest.txt 2>/dev/null || { echo "Смоук-тест завис"; pkill -x Mnemosyne; exit 1; }; echo

# Иконка из Sources/Mnemosyne/Raven.swift + scripts/make-icon.swift.
icon:
	cat Sources/Mnemosyne/Raven.swift scripts/make-icon.swift > $(TMPDIR)mnemosyne-icon.swift
	swift $(TMPDIR)mnemosyne-icon.swift Resources/AppIcon.icns

# Демо-встреча со всеми вкладками в ~/Meetings (удаляется как обычная встреча).
demo: app
	python3 scripts/make-demo.py
	MNEMOSYNE_RERENDER=D3E0D3E0-0000-4000-8000-000000000001 $(APP)/Contents/MacOS/Mnemosyne

# Образ для друзей: приложение и ярлык на «Программы».
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG     := build/Munin-$(VERSION).dmg
dmg: app
	rm -rf build/dmg $(DMG)
	mkdir -p build/dmg
	cp -R $(APP) build/dmg/
	ln -s /Applications build/dmg/Программы
	hdiutil create -volname "Мунин" -srcfolder build/dmg -fs HFS+ -format UDZO -ov $(DMG) >/dev/null
	rm -rf build/dmg
	@echo "Готово: $(DMG)"
