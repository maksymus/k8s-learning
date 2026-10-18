"""Tiny HTTP service that exists only to be pushed through the CI/CD pipeline."""
import os

from fastapi import FastAPI

app = FastAPI(title="demo-app")

# Baked into the image at build time (see Dockerfile), so you can see which build is live.
VERSION = os.getenv("APP_VERSION", "dev")


def greeting(name: str) -> str:
    name = name.strip()
    return f"Hello, {name.title()}!" if name else "Hello, stranger!"


@app.get("/")
def root():
    return {"service": "demo-app", "version": VERSION}


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/greet/{name}")
def greet(name: str):
    return {"message": greeting(name)}
