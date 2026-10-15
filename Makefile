.PHONY: ayuda instalar instalar-nucleo verificar lint capturar paquetes respaldo aplicar probar actualizar-upstream

ayuda:
	@echo 'instalar:        ./install.sh'
	@echo 'instalar-nucleo: ./install.sh --core-only'
	@echo 'verificar:       ./install.sh verify --force'
	@echo 'lint:            ./scripts/lint.sh --quick'
	@echo 'capturar:        ./scripts/capture.sh --list'
	@echo 'paquetes:        ./scripts/packages-update.sh --diff'
	@echo 'respaldo:        ./scripts/backup.sh'
	@echo 'aplicar:         ./install.sh dotfiles --force'
	@echo 'probar:          pruebas de parser y lint'
	@echo 'actualizar-upstream: actualización oficial con backup y revisión'

instalar:
	./install.sh
instalar-nucleo:
	./install.sh --core-only
verificar:
	./install.sh verify --force
lint:
	./scripts/lint.sh --quick
capturar:
	./scripts/capture.sh --list
paquetes:
	./scripts/packages-update.sh --diff
respaldo:
	./scripts/backup.sh
aplicar:
	./install.sh dotfiles --force

probar:
	bash tests/packages.sh
	bash tests/backup.sh
	./scripts/lint.sh --quick

actualizar-upstream:
	./scripts/update-upstream.sh
