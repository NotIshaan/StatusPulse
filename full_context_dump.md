### .dockerignore

```
__pycache__/
*.pyc
*.pyo
*.pyd
.env
.git
.gitignore
Dockerfile
docker-compose.yml
README.md
tests/
scripts/
terraform/
```

### .env

```
DB_HOST=postgres
DB_PORT=5432
DB_NAME=statuspulse
DB_USER=postgres
DB_PASSWORD=postgres

REDIS_HOST=redis
REDIS_PORT=6379
```

### .env.example

```example
DB_HOST=postgres
DB_PORT=5432
DB_NAME=statuspulse
DB_USER=postgres
DB_PASSWORD=postgres

REDIS_HOST=redis
REDIS_PORT=6379
```

### .github/workflows/ci.yml

```yaml
name: CI Pipeline

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main

jobs:
  build-and-test:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.11"

      - name: Lint Python code with ruff
        run: |
          pip install ruff
          ruff check app/

      - name: Lint Dockerfile with hadolint
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: Dockerfile
          ignore: DL3018

      - name: Create temporary .env file for CI
        run: cp .env.example .env

      - name: Build Docker image
        run: docker compose build

      - name: Start full stack via Docker Compose
        run: docker compose up -d

      - name: Wait for services to become healthy
        run: |
          echo "Waiting for services to initialize..."
          sleep 30
          docker compose ps

      - name: Run integration tests
        run: |
          chmod +x tests/test_integration.sh
          ./tests/test_integration.sh > test_results.txt
          cat test_results.txt

      - name: Tear down the stack
        if: always()
        run: docker compose down -v

      - name: Upload test results artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: integration-test-results
          path: test_results.txt
```

### .github/workflows/deploy.yml

```yaml
name: Deploy Pipeline

on:
  push:
    branches:
      - main

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  build-and-push-image:
    runs-on: ubuntu-latest
    
    # Sets the permissions granted to the GITHUB_TOKEN for the actions in this job.
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Log in to the Container registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract metadata (tags, labels) for Docker
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=sha,format=long
            type=raw,value=latest

      - name: Build and push Docker image
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
```

### .gitignore

```
.env
.terraform/
*.tfstate
*.tfstate.backup
```

### Caddyfile

```caddyfile
ishaan-statuspulse.duckdns.org {
    reverse_proxy app:8000
}
```

### Dockerfile

```dockerfile
# -------- Builder Stage --------
FROM python:3.11-alpine AS builder

WORKDIR /app

# Install build dependencies for Alpine
RUN apk add --no-cache gcc musl-dev postgresql-dev

COPY app/requirements.txt .

RUN pip install --user --no-cache-dir -r requirements.txt

# -------- Runtime Stage --------
FROM python:3.11-alpine

WORKDIR /app

# Install runtime postgres library and create user
RUN apk add --no-cache libpq && adduser -D appuser

# Copy dependencies
COPY --from=builder /root/.local /home/appuser/.local

# Copy app
COPY app/ .

ENV PATH=/home/appuser/.local/bin:$PATH

USER appuser

EXPOSE 8000

# Healthcheck
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health').read()"

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### Makefile

```makefile
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
```

### app/main.py

```python
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from datetime import datetime, timezone
import os
import redis
import psycopg2
import json

app = FastAPI(title="StatusPulse", version="1.0.0")

def get_db_connection():
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
    )

def get_redis_connection():
    return redis.Redis(
        host=os.environ.get("REDIS_HOST", "redis"),
        port=int(os.environ.get("REDIS_PORT", "6379")),
        password=os.environ.get("REDIS_PASSWORD", None),
        decode_responses=True,
    )

def init_db():
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute("""
        CREATE TABLE IF NOT EXISTS services (
            id SERIAL PRIMARY KEY,
            name VARCHAR(100) UNIQUE NOT NULL,
            url VARCHAR(500) NOT NULL,
            status VARCHAR(20) DEFAULT 'unknown',
            last_checked TIMESTAMP,
            response_time_ms INTEGER
        )
    """)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS incidents (
            id SERIAL PRIMARY KEY,
            service_name VARCHAR(100) NOT NULL,
            title VARCHAR(200) NOT NULL,
            description TEXT,
            severity VARCHAR(20) DEFAULT 'minor',
            status VARCHAR(20) DEFAULT 'investigating',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            resolved_at TIMESTAMP
        )
    """)
    conn.commit()
    cur.close()
    conn.close()

@app.on_event("startup")
async def startup():
    init_db()

@app.get("/health")
def health_check():
    checks = {"api": "healthy", "database": "unknown", "redis": "unknown"}
    
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute("SELECT 1")
        cur.close()
        conn.close()
        checks["database"] = "healthy"
    except Exception as e:
        checks["database"] = f"unhealthy: {str(e)}"
        
    try:
        r = get_redis_connection()
        r.ping()
        checks["redis"] = "healthy"
    except Exception as e:
        checks["redis"] = f"unhealthy: {str(e)}"
        
    overall = (
        "healthy"
        if all(v == "healthy" for v in checks.values())
        else "degraded"
    )
    
    return {
        "status": overall,
        "checks": checks,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }

class ServiceCreate(BaseModel):
    name: str
    url: str

@app.post("/services")
def add_service(service: ServiceCreate):
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            "INSERT INTO services (name, url) VALUES (%s, %s) RETURNING id",
            (service.name, service.url),
        )
        service_id = cur.fetchone()[0]
        conn.commit()
        return {"id": service_id, "name": service.name, "url": service.url}
    except psycopg2.errors.UniqueViolation:
        conn.rollback()
        raise HTTPException(status_code=409, detail="Service already exists")
    finally:
        cur.close()
        conn.close()

@app.get("/services")
def list_services():
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute(
        "SELECT id, name, url, status, last_checked, response_time_ms "
        "FROM services"
    )
    rows = cur.fetchall()
    cur.close()
    conn.close()
    
    return [
        {
            "id": r[0], "name": r[1], "url": r[2],
            "status": r[3], "last_checked": str(r[4]),
            "response_time_ms": r[5],
        }
        for r in rows
    ]

class IncidentCreate(BaseModel):
    service_name: str
    title: str
    description: str = ""
    severity: str = "minor"

@app.post("/incidents")
def create_incident(incident: IncidentCreate):
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO incidents (service_name, title, description, severity) "
        "VALUES (%s, %s, %s, %s) RETURNING id",
        (incident.service_name, incident.title, incident.description, incident.severity),
    )
    incident_id = cur.fetchone()[0]
    conn.commit()
    cur.close()
    conn.close()
    
    try:
        r = get_redis_connection()
        r.publish(
            "incidents",
            json.dumps({
                "id": incident_id,
                "title": incident.title,
                "severity": incident.severity,
            }),
        )
    except Exception:
        pass
        
    return {"id": incident_id, "status": "investigating"}

@app.get("/incidents")
def list_incidents():
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute(
        "SELECT id, service_name, title, severity, status, "
        "created_at, resolved_at FROM incidents ORDER BY created_at DESC"
    )
    rows = cur.fetchall()
    cur.close()
    conn.close()
    
    return [
        {
            "id": r[0], "service_name": r[1], "title": r[2],
            "severity": r[3], "status": r[4],
            "created_at": str(r[5]), "resolved_at": str(r[6]),
        }
        for r in rows
    ]

@app.get("/")
def root():
    return {
        "service": "StatusPulse",
        "version": "1.0.0",
        "docs": "/docs",
        "health": "/health",
    }
```

### app/requirements.txt

```txt
fastapi==0.104.1
uvicorn==0.24.0
gunicorn==21.2.0
psycopg2-binary==2.9.9
redis==5.0.1
pydantic==2.5.2
```

### deploy.sh

```bash
#!/bin/bash
set -e

echo "Pulling latest Docker image..."
docker compose -f docker-compose.prod.yml pull

echo "Starting up the server..."
docker compose -f docker-compose.prod.yml up -d

echo "Deploy complete!"
```

### docker-compose.prod.yml

```yaml
services:
  app:
    image: ghcr.io/notishaan/statuspulse:latest
    restart: always
    env_file: .env
    depends_on:
      - db
      - redis

  db:
    image: postgres:15-alpine
    restart: always
    env_file: .env
    volumes:
      - postgres_data:/var/lib/postgresql/data

  redis:
    image: redis:7-alpine
    restart: always

  caddy:
    image: caddy:2-alpine
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - app

volumes:
  postgres_data:
  caddy_data:
  caddy_config:
```

### docker-compose.yml

```yaml
version: "3.9"

services:
  app:
    build: .
    container_name: statuspulse_app
    ports:
      - "8000:8000"
    env_file:
      - .env
    depends_on:
      - postgres
      - redis
    networks:
      - statuspulse_net
    deploy:
      resources:
        limits:
          memory: 300m
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8000/health || exit 1"]
      interval: 30s
      retries: 3  


  postgres:
    image: postgres:15
    container_name: statuspulse_db
    environment:
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks:
      - statuspulse_net
    deploy:
      resources:
        limits:
          memory: 300m
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 30s
      retries: 3

  redis:
    image: redis:7
    container_name: statuspulse_redis
    networks:
      - statuspulse_net
    deploy:
      resources:
        limits:
          memory: 200m
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      retries: 3

volumes:
  pgdata:

networks:
  statuspulse_net:
    driver: bridge
```

### terraform/.terraform.lock.hcl

```hcl
# This file is maintained automatically by "terraform init".
# Manual edits may be lost in future updates.

provider "registry.terraform.io/hashicorp/aws" {
  version = "6.44.0"
  hashes = [
    "h1:ycsDqsaBxoZmyx9tZKxOFinhpb0oDAGryioYuF1LvfA=",
    "zh:0462747d28f6dcd7b1b723bea9da1600526b7cdcf929ed4be54352d74b0746e6",
    "zh:0c9b7e7b04050360f609ff5700d8a76227fb4ea84dac92b844d82a2013706705",
    "zh:2877a6854edf237f9d6c66dc928294cbbcf29d3f52577fb8f232d0cfd11d5c0d",
    "zh:3347b82e222bbfad326b79c408e53a9252b80c6c762f4dd4f4617583394f0a4e",
    "zh:33997dbe611b5abf49c87a31f29d8f797c97421f67b71fec8aa688799511b758",
    "zh:5d5c37375c5e776e6e8f95fb8cbd8009258618b9f51c55551a18adc09ef5814a",
    "zh:67d6bd61c52ca5f4c37c96a76f6820c9f1902e4b83f89faddf9fd7f17ba0b160",
    "zh:739588639fa30db7084d6939c2eb9b4dd2d7f58dbb5d5b3b2c4bda2a35dcf521",
    "zh:9b12af85486a96aedd8d7984b0ff811a4b42e3d88dad1a3fb4c0b580d04fa425",
    "zh:a953797142df4245bd8f456b9e78690f501a0fff2f58552db4eb2da409cd99e9",
    "zh:aeb8d616dd34a9f1c5048ed4cdd6d7692db93cd33a468872618d4cd38c4784aa",
    "zh:dc8420556aca50658247b097de6734259fc3a6012ff1cf96612fca10b3982f9d",
    "zh:f9083d6d9fb9cbdcd91e38c92f96e67223ecc7ce6d0986bd5eb8e6d52e9aa02b",
    "zh:f9418aa1e4d29f9026aa6f521e97d085e000902ea929debbbef61135185e3ad4",
    "zh:fb2494a6c92118055cfb2c114a4fe5c750946a1b0d6be6bf02ab3e37a091fb8b",
  ]
}
```

### terraform/.terraform/providers/registry.terraform.io/hashicorp/aws/6.44.0/linux_amd64/LICENSE.txt

```txt
Copyright IBM Corp. 2014, 2026

Mozilla Public License Version 2.0
==================================

1. Definitions
--------------

1.1. "Contributor"
    means each individual or legal entity that creates, contributes to
    the creation of, or owns Covered Software.

1.2. "Contributor Version"
    means the combination of the Contributions of others (if any) used
    by a Contributor and that particular Contributor's Contribution.

1.3. "Contribution"
    means Covered Software of a particular Contributor.

1.4. "Covered Software"
    means Source Code Form to which the initial Contributor has attached
    the notice in Exhibit A, the Executable Form of such Source Code
    Form, and Modifications of such Source Code Form, in each case
    including portions thereof.

1.5. "Incompatible With Secondary Licenses"
    means

    (a) that the initial Contributor has attached the notice described
        in Exhibit B to the Covered Software; or

    (b) that the Covered Software was made available under the terms of
        version 1.1 or earlier of the License, but not also under the
        terms of a Secondary License.

1.6. "Executable Form"
    means any form of the work other than Source Code Form.

1.7. "Larger Work"
    means a work that combines Covered Software with other material, in
    a separate file or files, that is not Covered Software.

1.8. "License"
    means this document.

1.9. "Licensable"
    means having the right to grant, to the maximum extent possible,
    whether at the time of the initial grant or subsequently, any and
    all of the rights conveyed by this License.

1.10. "Modifications"
    means any of the following:

    (a) any file in Source Code Form that results from an addition to,
        deletion from, or modification of the contents of Covered
        Software; or

    (b) any new file in Source Code Form that contains any Covered
        Software.

1.11. "Patent Claims" of a Contributor
    means any patent claim(s), including without limitation, method,
    process, and apparatus claims, in any patent Licensable by such
    Contributor that would be infringed, but for the grant of the
    License, by the making, using, selling, offering for sale, having
    made, import, or transfer of either its Contributions or its
    Contributor Version.

1.12. "Secondary License"
    means either the GNU General Public License, Version 2.0, the GNU
    Lesser General Public License, Version 2.1, the GNU Affero General
    Public License, Version 3.0, or any later versions of those
    licenses.

1.13. "Source Code Form"
    means the form of the work preferred for making modifications.

1.14. "You" (or "Your")
    means an individual or a legal entity exercising rights under this
    License. For legal entities, "You" includes any entity that
    controls, is controlled by, or is under common control with You. For
    purposes of this definition, "control" means (a) the power, direct
    or indirect, to cause the direction or management of such entity,
    whether by contract or otherwise, or (b) ownership of more than
    fifty percent (50%) of the outstanding shares or beneficial
    ownership of such entity.

2. License Grants and Conditions
--------------------------------

2.1. Grants

Each Contributor hereby grants You a world-wide, royalty-free,
non-exclusive license:

(a) under intellectual property rights (other than patent or trademark)
    Licensable by such Contributor to use, reproduce, make available,
    modify, display, perform, distribute, and otherwise exploit its
    Contributions, either on an unmodified basis, with Modifications, or
    as part of a Larger Work; and

(b) under Patent Claims of such Contributor to make, use, sell, offer
    for sale, have made, import, and otherwise transfer either its
    Contributions or its Contributor Version.

2.2. Effective Date

The licenses granted in Section 2.1 with respect to any Contribution
become effective for each Contribution on the date the Contributor first
distributes such Contribution.

2.3. Limitations on Grant Scope

The licenses granted in this Section 2 are the only rights granted under
this License. No additional rights or licenses will be implied from the
distribution or licensing of Covered Software under this License.
Notwithstanding Section 2.1(b) above, no patent license is granted by a
Contributor:

(a) for any code that a Contributor has removed from Covered Software;
    or

(b) for infringements caused by: (i) Your and any other third party's
    modifications of Covered Software, or (ii) the combination of its
    Contributions with other software (except as part of its Contributor
    Version); or

(c) under Patent Claims infringed by Covered Software in the absence of
    its Contributions.

This License does not grant any rights in the trademarks, service marks,
or logos of any Contributor (except as may be necessary to comply with
the notice requirements in Section 3.4).

2.4. Subsequent Licenses

No Contributor makes additional grants as a result of Your choice to
distribute the Covered Software under a subsequent version of this
License (see Section 10.2) or under the terms of a Secondary License (if
permitted under the terms of Section 3.3).

2.5. Representation

Each Contributor represents that the Contributor believes its
Contributions are its original creation(s) or it has sufficient rights
to grant the rights to its Contributions conveyed by this License.

2.6. Fair Use

This License is not intended to limit any rights You have under
applicable copyright doctrines of fair use, fair dealing, or other
equivalents.

2.7. Conditions

Sections 3.1, 3.2, 3.3, and 3.4 are conditions of the licenses granted
in Section 2.1.

3. Responsibilities
-------------------

3.1. Distribution of Source Form

All distribution of Covered Software in Source Code Form, including any
Modifications that You create or to which You contribute, must be under
the terms of this License. You must inform recipients that the Source
Code Form of the Covered Software is governed by the terms of this
License, and how they can obtain a copy of this License. You may not
attempt to alter or restrict the recipients' rights in the Source Code
Form.

3.2. Distribution of Executable Form

If You distribute Covered Software in Executable Form then:

(a) such Covered Software must also be made available in Source Code
    Form, as described in Section 3.1, and You must inform recipients of
    the Executable Form how they can obtain a copy of such Source Code
    Form by reasonable means in a timely manner, at a charge no more
    than the cost of distribution to the recipient; and

(b) You may distribute such Executable Form under the terms of this
    License, or sublicense it under different terms, provided that the
    license for the Executable Form does not attempt to limit or alter
    the recipients' rights in the Source Code Form under this License.

3.3. Distribution of a Larger Work

You may create and distribute a Larger Work under terms of Your choice,
provided that You also comply with the requirements of this License for
the Covered Software. If the Larger Work is a combination of Covered
Software with a work governed by one or more Secondary Licenses, and the
Covered Software is not Incompatible With Secondary Licenses, this
License permits You to additionally distribute such Covered Software
under the terms of such Secondary License(s), so that the recipient of
the Larger Work may, at their option, further distribute the Covered
Software under the terms of either this License or such Secondary
License(s).

3.4. Notices

You may not remove or alter the substance of any license notices
(including copyright notices, patent notices, disclaimers of warranty,
or limitations of liability) contained within the Source Code Form of
the Covered Software, except that You may alter any license notices to
the extent required to remedy known factual inaccuracies.

3.5. Application of Additional Terms

You may choose to offer, and to charge a fee for, warranty, support,
indemnity or liability obligations to one or more recipients of Covered
Software. However, You may do so only on Your own behalf, and not on
behalf of any Contributor. You must make it absolutely clear that any
such warranty, support, indemnity, or liability obligation is offered by
You alone, and You hereby agree to indemnify every Contributor for any
liability incurred by such Contributor as a result of warranty, support,
indemnity or liability terms You offer. You may include additional
disclaimers of warranty and limitations of liability specific to any
jurisdiction.

4. Inability to Comply Due to Statute or Regulation
---------------------------------------------------

If it is impossible for You to comply with any of the terms of this
License with respect to some or all of the Covered Software due to
statute, judicial order, or regulation then You must: (a) comply with
the terms of this License to the maximum extent possible; and (b)
describe the limitations and the code they affect. Such description must
be placed in a text file included with all distributions of the Covered
Software under this License. Except to the extent prohibited by statute
or regulation, such description must be sufficiently detailed for a
recipient of ordinary skill to be able to understand it.

5. Termination
--------------

5.1. The rights granted under this License will terminate automatically
if You fail to comply with any of its terms. However, if You become
compliant, then the rights granted under this License from a particular
Contributor are reinstated (a) provisionally, unless and until such
Contributor explicitly and finally terminates Your grants, and (b) on an
ongoing basis, if such Contributor fails to notify You of the
non-compliance by some reasonable means prior to 60 days after You have
come back into compliance. Moreover, Your grants from a particular
Contributor are reinstated on an ongoing basis if such Contributor
notifies You of the non-compliance by some reasonable means, this is the
first time You have received notice of non-compliance with this License
from such Contributor, and You become compliant prior to 30 days after
Your receipt of the notice.

5.2. If You initiate litigation against any entity by asserting a patent
infringement claim (excluding declaratory judgment actions,
counter-claims, and cross-claims) alleging that a Contributor Version
directly or indirectly infringes any patent, then the rights granted to
You by any and all Contributors for the Covered Software under Section
2.1 of this License shall terminate.

5.3. In the event of termination under Sections 5.1 or 5.2 above, all
end user license agreements (excluding distributors and resellers) which
have been validly granted by You or Your distributors under this License
prior to termination shall survive termination.

************************************************************************
*                                                                      *
*  6. Disclaimer of Warranty                                           *
*  -------------------------                                           *
*                                                                      *
*  Covered Software is provided under this License on an "as is"       *
*  basis, without warranty of any kind, either expressed, implied, or  *
*  statutory, including, without limitation, warranties that the       *
*  Covered Software is free of defects, merchantable, fit for a        *
*  particular purpose or non-infringing. The entire risk as to the     *
*  quality and performance of the Covered Software is with You.        *
*  Should any Covered Software prove defective in any respect, You     *
*  (not any Contributor) assume the cost of any necessary servicing,   *
*  repair, or correction. This disclaimer of warranty constitutes an   *
*  essential part of this License. No use of any Covered Software is   *
*  authorized under this License except under this disclaimer.         *
*                                                                      *
************************************************************************

************************************************************************
*                                                                      *
*  7. Limitation of Liability                                          *
*  --------------------------                                          *
*                                                                      *
*  Under no circumstances and under no legal theory, whether tort      *
*  (including negligence), contract, or otherwise, shall any           *
*  Contributor, or anyone who distributes Covered Software as          *
*  permitted above, be liable to You for any direct, indirect,         *
*  special, incidental, or consequential damages of any character      *
*  including, without limitation, damages for lost profits, loss of    *
*  goodwill, work stoppage, computer failure or malfunction, or any    *
*  and all other commercial damages or losses, even if such party      *
*  shall have been informed of the possibility of such damages. This   *
*  limitation of liability shall not apply to liability for death or   *
*  personal injury resulting from such party's negligence to the       *
*  extent applicable law prohibits such limitation. Some               *
*  jurisdictions do not allow the exclusion or limitation of           *
*  incidental or consequential damages, so this exclusion and          *
*  limitation may not apply to You.                                    *
*                                                                      *
************************************************************************

8. Litigation
-------------

Any litigation relating to this License may be brought only in the
courts of a jurisdiction where the defendant maintains its principal
place of business and such litigation shall be governed by laws of that
jurisdiction, without reference to its conflict-of-law provisions.
Nothing in this Section shall prevent a party's ability to bring
cross-claims or counter-claims.

9. Miscellaneous
----------------

This License represents the complete agreement concerning the subject
matter hereof. If any provision of this License is held to be
unenforceable, such provision shall be reformed only to the extent
necessary to make it enforceable. Any law or regulation which provides
that the language of a contract shall be construed against the drafter
shall not be used to construe this License against a Contributor.

10. Versions of the License
---------------------------

10.1. New Versions

Mozilla Foundation is the license steward. Except as provided in Section
10.3, no one other than the license steward has the right to modify or
publish new versions of this License. Each version will be given a
distinguishing version number.

10.2. Effect of New Versions

You may distribute the Covered Software under the terms of the version
of the License under which You originally received the Covered Software,
or under the terms of any subsequent version published by the license
steward.

10.3. Modified Versions

If you create software not governed by this License, and you want to
create a new license for such software, you may create and use a
modified version of this License if you rename the license and remove
any references to the name of the license steward (except to note that
such modified license differs from this License).

10.4. Distributing Source Code Form that is Incompatible With Secondary
Licenses

If You choose to distribute Source Code Form that is Incompatible With
Secondary Licenses under the terms of this version of the License, the
notice described in Exhibit B of this License must be attached.

Exhibit A - Source Code Form License Notice
-------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at http://mozilla.org/MPL/2.0/.

If it is not possible or desirable to put the notice in a particular
file, then You may include the notice in a location (such as a LICENSE
file in a relevant directory) where a recipient would be likely to look
for such a notice.

You may add additional accurate notices of copyright ownership.

Exhibit B - "Incompatible With Secondary Licenses" Notice
---------------------------------------------------------

  This Source Code Form is "Incompatible With Secondary Licenses", as
  defined by the Mozilla Public License, v. 2.0.
```

### terraform/.terraform/providers/registry.terraform.io/hashicorp/aws/6.44.0/linux_amd64/terraform-provider-aws_v6.44.0_x5

```0_x5
# Error reading file: 'utf-8' codec can't decode byte 0x80 in position 24: invalid start byte
```

### terraform/main.tf

```terraform
provider "aws" {
  region = var.aws_region
}

# Fetch the latest Ubuntu 22.04 Free Tier AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# Create SSH Key Pair in AWS
resource "aws_key_pair" "deployer" {
  key_name   = "statuspulse-deployer-key"
  public_key = file(pathexpand(var.public_key_path))
}

# Security Group / Firewall
resource "aws_security_group" "statuspulse_sg" {
  name        = "statuspulse_sg"
  description = "Allow custom SSH, HTTP, and HTTPS inbound traffic"

  ingress {
    description = "Custom SSH"
    from_port   = var.ssh_port
    to_port     = var.ssh_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# The EC2 Instance
resource "aws_instance" "web" {
  ami             = data.aws_ami.ubuntu.id
  instance_type   = "t2.micro" # Free tier eligible
  key_name        = aws_key_pair.deployer.key_name
  security_groups = [aws_security_group.statuspulse_sg.name]

  # Pass the hardening script to run on boot
  user_data = file("${path.module}/userdata.sh")

  tags = {
    Name = "StatusPulse-Server"
  }
}
```

### terraform/outputs.tf

```terraform
output "server_public_ip" {
  description = "The public IP address of the web server"
  value       = aws_instance.web.public_ip
}
```

### terraform/terraform.tfstate

```tfstate
{
  "version": 4,
  "terraform_version": "1.14.8",
  "serial": 4,
  "lineage": "a6ffc16f-d3ea-ad72-464c-799bbfbf9b1a",
  "outputs": {
    "server_public_ip": {
      "value": "52.91.198.25",
      "type": "string"
    }
  },
  "resources": [
    {
      "mode": "data",
      "type": "aws_ami",
      "name": "ubuntu",
      "provider": "provider[\"registry.terraform.io/hashicorp/aws\"]",
      "instances": [
        {
          "schema_version": 0,
          "attributes": {
            "allow_unsafe_filter": null,
            "architecture": "x86_64",
            "arn": "arn:aws:ec2:us-east-1::image/ami-00403f401ee6a4b98",
            "block_device_mappings": [
              {
                "device_name": "/dev/sda1",
                "ebs": {
                  "delete_on_termination": "true",
                  "encrypted": "false",
                  "iops": "0",
                  "snapshot_id": "snap-05f163ab216d3dcd0",
                  "throughput": "0",
                  "volume_initialization_rate": "0",
                  "volume_size": "8",
                  "volume_type": "gp2"
                },
                "no_device": "",
                "virtual_name": ""
              },
              {
                "device_name": "/dev/sdb",
                "ebs": {},
                "no_device": "",
                "virtual_name": "ephemeral0"
              },
              {
                "device_name": "/dev/sdc",
                "ebs": {},
                "no_device": "",
                "virtual_name": "ephemeral1"
              }
            ],
            "boot_mode": "uefi-preferred",
            "creation_date": "2026-05-03T06:54:18.000Z",
            "deprecation_time": "2028-05-03T06:54:18.000Z",
            "description": "Canonical, Ubuntu, 22.04, amd64 jammy image",
            "ena_support": true,
            "executable_users": null,
            "filter": [
              {
                "name": "name",
                "values": [
                  "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
                ]
              }
            ],
            "hypervisor": "xen",
            "id": "ami-00403f401ee6a4b98",
            "image_id": "ami-00403f401ee6a4b98",
            "image_location": "amazon/ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-20260503",
            "image_owner_alias": "amazon",
            "image_type": "machine",
            "imds_support": "",
            "include_deprecated": false,
            "kernel_id": "",
            "last_launched_time": "",
            "most_recent": true,
            "name": "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-20260503",
            "name_regex": null,
            "owner_id": "099720109477",
            "owners": [
              "099720109477"
            ],
            "platform": "",
            "platform_details": "Linux/UNIX",
            "product_codes": [],
            "public": true,
            "ramdisk_id": "",
            "region": "us-east-1",
            "root_device_name": "/dev/sda1",
            "root_device_type": "ebs",
            "root_snapshot_id": "snap-05f163ab216d3dcd0",
            "sriov_net_support": "simple",
            "state": "available",
            "state_reason": {
              "code": "UNSET",
              "message": "UNSET"
            },
            "tags": {},
            "timeouts": null,
            "tpm_support": "",
            "uefi_data": null,
            "usage_operation": "RunInstances",
            "virtualization_type": "hvm"
          },
          "sensitive_attributes": [],
          "identity_schema_version": 0
        }
      ]
    },
    {
      "mode": "managed",
      "type": "aws_instance",
      "name": "web",
      "provider": "provider[\"registry.terraform.io/hashicorp/aws\"]",
      "instances": [
        {
          "schema_version": 2,
          "attributes": {
            "ami": "ami-00403f401ee6a4b98",
            "arn": "arn:aws:ec2:us-east-1:917891822252:instance/i-03da8ec3b27705048",
            "associate_public_ip_address": true,
            "availability_zone": "us-east-1c",
            "capacity_reservation_specification": [
              {
                "capacity_reservation_preference": "open",
                "capacity_reservation_target": []
              }
            ],
            "cpu_options": [
              {
                "amd_sev_snp": "",
                "core_count": 1,
                "nested_virtualization": "",
                "threads_per_core": 1
              }
            ],
            "credit_specification": [
              {
                "cpu_credits": "standard"
              }
            ],
            "disable_api_stop": false,
            "disable_api_termination": false,
            "ebs_block_device": [],
            "ebs_optimized": false,
            "enable_primary_ipv6": null,
            "enclave_options": [
              {
                "enabled": false
              }
            ],
            "ephemeral_block_device": [],
            "force_destroy": false,
            "get_password_data": false,
            "hibernation": false,
            "host_id": "",
            "host_resource_group_arn": null,
            "iam_instance_profile": "",
            "id": "i-03da8ec3b27705048",
            "instance_initiated_shutdown_behavior": "stop",
            "instance_lifecycle": "",
            "instance_market_options": [],
            "instance_state": "running",
            "instance_type": "t2.micro",
            "ipv6_address_count": 0,
            "ipv6_addresses": [],
            "key_name": "statuspulse-deployer-key",
            "launch_template": [],
            "maintenance_options": [
              {
                "auto_recovery": "default"
              }
            ],
            "metadata_options": [
              {
                "http_endpoint": "enabled",
                "http_protocol_ipv6": "disabled",
                "http_put_response_hop_limit": 1,
                "http_tokens": "optional",
                "instance_metadata_tags": "disabled"
              }
            ],
            "monitoring": false,
            "network_interface": [],
            "outpost_arn": "",
            "password_data": "",
            "placement_group": "",
            "placement_group_id": "",
            "placement_partition_number": 0,
            "primary_network_interface": [
              {
                "delete_on_termination": true,
                "network_interface_id": "eni-0ed15b00eb3cad38e"
              }
            ],
            "primary_network_interface_id": "eni-0ed15b00eb3cad38e",
            "private_dns": "ip-172-31-29-134.ec2.internal",
            "private_dns_name_options": [
              {
                "enable_resource_name_dns_a_record": false,
                "enable_resource_name_dns_aaaa_record": false,
                "hostname_type": "ip-name"
              }
            ],
            "private_ip": "172.31.29.134",
            "public_dns": "ec2-52-91-198-25.compute-1.amazonaws.com",
            "public_ip": "52.91.198.25",
            "region": "us-east-1",
            "root_block_device": [
              {
                "delete_on_termination": true,
                "device_name": "/dev/sda1",
                "encrypted": false,
                "iops": 100,
                "kms_key_id": "",
                "tags": {},
                "tags_all": {},
                "throughput": 0,
                "volume_id": "vol-07a5883ebd3900777",
                "volume_size": 8,
                "volume_type": "gp2"
              }
            ],
            "secondary_network_interface": [],
            "secondary_private_ips": [],
            "security_groups": [
              "statuspulse_sg"
            ],
            "source_dest_check": true,
            "spot_instance_request_id": "",
            "subnet_id": "subnet-02d4e19215ef337ea",
            "tags": {
              "Name": "StatusPulse-Server"
            },
            "tags_all": {
              "Name": "StatusPulse-Server"
            },
            "tenancy": "default",
            "timeouts": null,
            "user_data": "#!/bin/bash\nset -e\n\n# 1. Create 2GB Swap Space (Crucial for 1GB RAM t2.micro)\nfallocate -l 2G /swapfile\nchmod 600 /swapfile\nmkswap /swapfile\nswapon /swapfile\necho '/swapfile none swap sw 0 0' \u003e\u003e /etc/fstab\n\n# 2. Create non-root deploy user\nuseradd -m -s /bin/bash deploy\nusermod -aG sudo deploy\n\n# 3. Install Docker, UFW, and unattended-upgrades\napt-get update\napt-get install -y ca-certificates curl gnupg ufw unattended-upgrades\ninstall -m 0755 -d /etc/apt/keyrings\ncurl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg\nchmod a+r /etc/apt/keyrings/docker.gpg\necho \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\" | tee /etc/apt/sources.list.d/docker.list \u003e /dev/null\napt-get update\napt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin\n\n# 4. Add users to docker group\nusermod -aG docker ubuntu\nusermod -aG docker deploy\n\n# 5. Copy SSH keys to deploy user\nmkdir -p /home/deploy/.ssh\ncp /home/ubuntu/.ssh/authorized_keys /home/deploy/.ssh/\nchown -R deploy:deploy /home/deploy/.ssh\nchmod 700 /home/deploy/.ssh\nchmod 600 /home/deploy/.ssh/authorized_keys\n\n# 6. Configure UFW Firewall\nufw default deny incoming\nufw default allow outgoing\nufw allow 2222/tcp\nufw allow 80/tcp\nufw allow 443/tcp\nufw --force enable\n\n# 7. SSH Hardening\nsed -i 's/#Port 22/Port 2222/' /etc/ssh/sshd_config\nsed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config\nsed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config\nsystemctl restart sshd\n\n# 8. Enable automatic security updates\necho 'APT::Periodic::Update-Package-Lists \"1\";' \u003e /etc/apt/apt.conf.d/20auto-upgrades\necho 'APT::Periodic::Unattended-Upgrade \"1\";' \u003e\u003e /etc/apt/apt.conf.d/20auto-upgrades\n",
            "user_data_base64": null,
            "user_data_replace_on_change": false,
            "volume_tags": null,
            "vpc_security_group_ids": [
              "sg-0db542c939bbe6bb9"
            ]
          },
          "sensitive_attributes": [],
          "identity_schema_version": 0,
          "identity": {
            "account_id": "917891822252",
            "id": "i-03da8ec3b27705048",
            "region": "us-east-1"
          },
          "private": "eyJlMmJmYjczMC1lY2FhLTExZTYtOGY4OC0zNDM2M2JjN2M0YzAiOnsiY3JlYXRlIjo2MDAwMDAwMDAwMDAsImRlbGV0ZSI6MTIwMDAwMDAwMDAwMCwicmVhZCI6OTAwMDAwMDAwMDAwLCJ1cGRhdGUiOjYwMDAwMDAwMDAwMH0sInNjaGVtYV92ZXJzaW9uIjoiMiJ9",
          "dependencies": [
            "aws_key_pair.deployer",
            "aws_security_group.statuspulse_sg",
            "data.aws_ami.ubuntu"
          ]
        }
      ]
    },
    {
      "mode": "managed",
      "type": "aws_key_pair",
      "name": "deployer",
      "provider": "provider[\"registry.terraform.io/hashicorp/aws\"]",
      "instances": [
        {
          "schema_version": 1,
          "attributes": {
            "arn": "arn:aws:ec2:us-east-1:917891822252:key-pair/statuspulse-deployer-key",
            "fingerprint": "AZ0FAIMEXRLpdoGwFWTDw1wUW8M4H9lqiCuTT7HAneY=",
            "id": "statuspulse-deployer-key",
            "key_name": "statuspulse-deployer-key",
            "key_name_prefix": "",
            "key_pair_id": "key-0147b232d774cd49e",
            "key_type": "ed25519",
            "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPmf8l7m+7T7qx8scp3LxrpXV43WiThXHQ+AM71+7taQ ishaanworks24@gmail.com",
            "region": "us-east-1",
            "tags": null,
            "tags_all": {}
          },
          "sensitive_attributes": [],
          "identity_schema_version": 0,
          "private": "eyJzY2hlbWFfdmVyc2lvbiI6IjEifQ=="
        }
      ]
    },
    {
      "mode": "managed",
      "type": "aws_security_group",
      "name": "statuspulse_sg",
      "provider": "provider[\"registry.terraform.io/hashicorp/aws\"]",
      "instances": [
        {
          "schema_version": 1,
          "attributes": {
            "arn": "arn:aws:ec2:us-east-1:917891822252:security-group/sg-0db542c939bbe6bb9",
            "description": "Allow custom SSH, HTTP, and HTTPS inbound traffic",
            "egress": [
              {
                "cidr_blocks": [
                  "0.0.0.0/0"
                ],
                "description": "",
                "from_port": 0,
                "ipv6_cidr_blocks": [],
                "prefix_list_ids": [],
                "protocol": "-1",
                "security_groups": [],
                "self": false,
                "to_port": 0
              }
            ],
            "id": "sg-0db542c939bbe6bb9",
            "ingress": [
              {
                "cidr_blocks": [
                  "0.0.0.0/0"
                ],
                "description": "Custom SSH",
                "from_port": 2222,
                "ipv6_cidr_blocks": [],
                "prefix_list_ids": [],
                "protocol": "tcp",
                "security_groups": [],
                "self": false,
                "to_port": 2222
              },
              {
                "cidr_blocks": [
                  "0.0.0.0/0"
                ],
                "description": "HTTP",
                "from_port": 80,
                "ipv6_cidr_blocks": [],
                "prefix_list_ids": [],
                "protocol": "tcp",
                "security_groups": [],
                "self": false,
                "to_port": 80
              },
              {
                "cidr_blocks": [
                  "0.0.0.0/0"
                ],
                "description": "HTTPS",
                "from_port": 443,
                "ipv6_cidr_blocks": [],
                "prefix_list_ids": [],
                "protocol": "tcp",
                "security_groups": [],
                "self": false,
                "to_port": 443
              }
            ],
            "name": "statuspulse_sg",
            "name_prefix": "",
            "owner_id": "917891822252",
            "region": "us-east-1",
            "revoke_rules_on_delete": false,
            "tags": null,
            "tags_all": {},
            "timeouts": null,
            "vpc_id": "vpc-0ce116235f2ed65e6"
          },
          "sensitive_attributes": [],
          "identity_schema_version": 0,
          "identity": {
            "account_id": "917891822252",
            "id": "sg-0db542c939bbe6bb9",
            "region": "us-east-1"
          },
          "private": "eyJlMmJmYjczMC1lY2FhLTExZTYtOGY4OC0zNDM2M2JjN2M0YzAiOnsiY3JlYXRlIjo2MDAwMDAwMDAwMDAsImRlbGV0ZSI6OTAwMDAwMDAwMDAwfSwic2NoZW1hX3ZlcnNpb24iOiIxIn0="
        }
      ]
    }
  ],
  "check_results": null
}
```

### terraform/userdata.sh

```bash
#!/bin/bash
set -e

# 1. Create 2GB Swap Space (Crucial for 1GB RAM t2.micro)
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# 2. Create non-root deploy user
useradd -m -s /bin/bash deploy
usermod -aG sudo deploy

# 3. Install Docker, UFW, and unattended-upgrades
apt-get update
apt-get install -y ca-certificates curl gnupg ufw unattended-upgrades
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 4. Add users to docker group
usermod -aG docker ubuntu
usermod -aG docker deploy

# 5. Copy SSH keys to deploy user
mkdir -p /home/deploy/.ssh
cp /home/ubuntu/.ssh/authorized_keys /home/deploy/.ssh/
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/authorized_keys

# 6. Configure UFW Firewall
ufw default deny incoming
ufw default allow outgoing
ufw allow 2222/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# 7. SSH Hardening
sed -i 's/#Port 22/Port 2222/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd

# 8. Enable automatic security updates
echo 'APT::Periodic::Update-Package-Lists "1";' > /etc/apt/apt.conf.d/20auto-upgrades
echo 'APT::Periodic::Unattended-Upgrade "1";' >> /etc/apt/apt.conf.d/20auto-upgrades
```

### terraform/variables.tf

```terraform
variable "aws_region" {
  description = "The AWS region to deploy to"
  default     = "us-east-1"
}

variable "ssh_port" {
  description = "Custom SSH port for security hardening"
  default     = 2222
}

variable "public_key_path" {
  description = "Path to your local SSH public key"
  default     = "~/.ssh/id_ed25519.pub"
}
```

### tests/test_integration.sh

```bash
#!/bin/bash
set -e # Exit immediately if a test fails

BASE_URL="http://127.0.0.1:8000"
echo "Starting Integration Tests..."

# Helper functions
pass() { echo " $1: PASS"; }
fail() { echo " $1: FAIL"; exit 1; }

# 1. GET /health
echo "Testing GET /health..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" "$BASE_URL/health")
if [ "$HTTP_CODE" -eq 200 ] && grep -q '"status":"healthy"' response.json; then
    pass "GET /health"
else
    fail "GET /health"
fi

# 2. POST /services
echo "Testing POST /services..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -X POST "$BASE_URL/services" -H "Content-Type: application/json" -d '{"name": "test-service", "url": "http://example.com"}')
if [ "$HTTP_CODE" -eq 200 ] && grep -q '"id"' response.json; then
    pass "POST /services (Create)"
else
    fail "POST /services (Create)"
fi

# 3. POST /services (Duplicate - Must be 409)
echo "Testing POST /services (Duplicate)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/services" -H "Content-Type: application/json" -d '{"name": "test-service", "url": "http://example.com"}')
if [ "$HTTP_CODE" -eq 409 ]; then
    pass "POST /services (Duplicate 409 Conflict)"
else
    fail "POST /services (Duplicate)"
fi

# 4. GET /services
echo "Testing GET /services..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" "$BASE_URL/services")
if [ "$HTTP_CODE" -eq 200 ] && grep -q '"name":"test-service"' response.json; then
    pass "GET /services"
else
    fail "GET /services"
fi

# 5. POST /incidents
echo "Testing POST /incidents..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -X POST "$BASE_URL/incidents" -H "Content-Type: application/json" -d '{"service_name": "test-service", "title": "Server down", "severity": "major"}')
if [ "$HTTP_CODE" -eq 200 ] && grep -q '"status":"investigating"' response.json; then
    pass "POST /incidents"
else
    fail "POST /incidents"
fi

# 6. GET /incidents
echo "Testing GET /incidents..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" "$BASE_URL/incidents")
if [ "$HTTP_CODE" -eq 200 ] && grep -q '"title":"Server down"' response.json; then
    pass "GET /incidents"
else
    fail "GET /incidents"
fi

# Cleanup
rm -f response.json

echo "All tests passed."
```

