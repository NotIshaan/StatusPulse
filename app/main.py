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
