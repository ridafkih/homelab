COMPOSE=docker compose -f /Users/ridafkih/homelab/compose.yaml

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
