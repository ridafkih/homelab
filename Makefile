.EXPORT_ALL_VARIABLES:

COMPOSE_PROFILES=network,ai,media

COMPOSE=docker compose

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart

pull:
	$(COMPOSE) pull

update: pull up

ps:
	$(COMPOSE) ps
