build:
	docker compose build

up:
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f

test:
	curl -s http://localhost:8000/health | grep healthy && echo "PASS" || echo "FAIL"

clean:
	docker compose down -v --rmi all

shell:
	docker exec -it statuspulse_app bash
