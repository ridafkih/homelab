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

logs:
	$(COMPOSE) logs -f --tail=200

ps:
	$(COMPOSE) ps
