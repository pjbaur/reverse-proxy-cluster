FROM python:3.12-alpine
WORKDIR /app
COPY server.py .
USER nobody
EXPOSE 8080
CMD ["python3", "-u", "server.py"]
