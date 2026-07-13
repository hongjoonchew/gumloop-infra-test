FROM python:3.12-alpine3.20

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8080

CMD ["gunicorn", \
     "-w", "2", \
     "-k", "sync", \
     "-b", "0.0.0.0:8080", \
     "--max-requests", "1000", \
     "--max-requests-jitter", "100", \
     "--timeout", "30", \
     "main:app"]
