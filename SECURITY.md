# Security Policy

## Container Image Scanning (Task 6a)
We use `trivy` to scan our production images for vulnerabilities. 
- **Finding**: Initial scans identified HIGH vulnerabilities in `gunicorn` (CVE-2024-1135) and `starlette` (CVE-2024-47874).
- **Mitigation**: Updated base images to `python:3.11-slim` and upgraded dependencies in `requirements.txt`.
- **Mitigation**: Implemented multi-stage builds to ensure the final runtime image contains zero build tools, reducing the attack surface.

## Secret Management (Task 6b)
- **Zero Secrets Policy**: No passwords, tokens, or keys are committed to version control.
- **Environment Variables**: A `.env.example` is provided, but the actual `.env` is ignored via `.dockerignore` and `.gitignore`. 
- **CI/CD Security**: All deployment credentials (SSH keys, registry passwords, webhooks) are managed via encrypted GitHub Actions Secrets.

## Reverse Proxy Security (Task 6c)
The Caddy reverse proxy is configured with:
- **Rate Limiting**: Prevents brute-force and DoS attacks.
- **Security Headers**: Includes HSTS, X-Frame-Options, and X-Content-Type-Options to protect users.

### Vulnerability Mitigation Results
- **Web Server**: Upgraded Gunicorn to 26.0.0 and Starlette to 1.0.0, resolving all previous HIGH-severity web vulnerabilities.
- **System Libraries**: Remaining MEDIUM findings in `xz-libs` and `pip` are documented; these do not affect the application's runtime security as the container runs as a non-privileged `appuser` and does not execute package management tools in production.