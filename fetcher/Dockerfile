# Image of Fetcher. Built in fetcher-vm by provision/fetcher.sh:
#   docker build -t weather-fetcher:local /home/vagrant/weather-history/fetcher
# One stage is enough: httpx, pika and python-dotenv are pure Python, and psycopg[binary]
# comes as a ready binary package with its own libpq (no compiler needed).
# Python 3.12 — the same version as in Ubuntu 24.04, where Fetcher ran before.
FROM python:3.12-slim

# A user without root rights; created before the code so this layer is cached.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin fetcher
 # Dependencies first: this layer is rebuilt only when requirements.txt changes,
# not on every code change.
COPY requirements.txt .
# --root-user-action=ignore: pip runs as root here on purpose (the image has no other Python).
RUN pip install --no-cache-dir --disable-pip-version-check --root-user-action=ignore \
    -r requirements.txt

# Only the program files. No .env: settings come from docker run --env-file.
COPY main.py config.py messages.py pgqueue.py weather.py ./

USER fetcher
CMD ["python", "main.py"]
