from app import app
import pytest

def test_answer():
    response = app.test_client().get('/ping')

    assert response.status_code == 200