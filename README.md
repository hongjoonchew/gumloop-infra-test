# Gumloop Infrastructure Engineer

Welcome!  
This repo contains a minimal Flask API you’ll containerise, deploy to Kubernetes, and wire into a CI/CD workflow during the live technical interview.

## Quick start (local)

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python app/main.py  # → listen on http://localhost:8080
```

## Your tasks during the interview

> 60 min hands-on – focus on best practices, not completeness.

1. Create a secure, slim Dockerfile that serves this API.

2. Add k8s / manifests (deployment.yaml, service.yaml, hpa.yaml) with sensible defaults.

3. Deploy to GCP or similar cloud provider

4. Set up a lightweight CI/CD workflow (GitHub Actions or similar) that:

- Builds & pushes the container image

- Deploys it to a demo GKE namespace (or another cluster you choose)

5. Document any scaling / hardening next steps in this README.md (≤ 150 words).

Feel free to use any public docs, AI, or personal snippets. If you paste large blocks verbatim, add a brief citation comment.

Good luck – we’re excited to see your approach!
