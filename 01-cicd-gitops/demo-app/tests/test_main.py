from fastapi.testclient import TestClient

from demo_app.main import app, greeting

client = TestClient(app)


def test_root_reports_version():
    response = client.get("/")
    assert response.status_code == 200
    assert response.json()["service"] == "demo-app"
    assert "version" in response.json()


def test_healthz():
    assert client.get("/healthz").json() == {"status": "ok"}


def test_greet_endpoint():
    assert client.get("/greet/ada").json() == {"message": "Hello, Ada!"}


def test_greeting_trims_whitespace():
    assert greeting("  grace hopper ") == "Hello, Grace Hopper!"


def test_greeting_empty_name():
    assert greeting("   ") == "Hello, stranger!"
