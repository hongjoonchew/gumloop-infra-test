from app.main import app


def test_root():
    client = app.test_client()
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.json == {"status": "ok"}


def test_metrics_endpoint_exposes_request_counter():
    client = app.test_client()
    # Generate one sample per status class so the counter has series to expose.
    assert client.get("/").status_code == 200
    assert client.get("/notfound").status_code == 404
    assert client.get("/boom").status_code == 500

    resp = client.get("/metrics")
    assert resp.status_code == 200
    body = resp.get_data(as_text=True)
    assert "flask_http_request_total" in body
    assert 'status="200"' in body
    assert 'status="404"' in body
    assert 'status="500"' in body
