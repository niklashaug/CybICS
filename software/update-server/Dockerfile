FROM python:3.12-slim

WORKDIR /opt/cybics/update-server

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY entrypoint.sh .
RUN chmod +x /opt/cybics/update-server/entrypoint.sh \
    && mkdir -p /opt/cybics/update-server/firmware /opt/cybics/secrets

EXPOSE 6689

ENTRYPOINT ["/opt/cybics/update-server/entrypoint.sh"]
