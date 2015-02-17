Docker PAAS
===========

## Key Componets

* [Docker](http://github.com/docker/docker)
* [Docker Compose](https://github.com/docker/fig)
* [Hipache](https://github.com/hipache/hipache)

## Configuration

* `PAAS_HIPACHE_DIR`
* `PAAS_APP_DOMAIN`
* `PAAS_APP_DIR`

## Directory setup

```
var
+-- www
     |-- config
     |   |-- setup.sh
     |   +-- manage.sh
     +-- apps
          +-- myapp
               |-- docker-compose.yml
               +-- Dockerfile
```

## Applications

Applications must be placed inside the `/apps` directory.

### Web-workers

Web worker is the container you want exposed to the public Internet – in most
cases this is your primary application. Each project may only have **one**
web-worker and it must be exposing port `8080`. This is how you specify one:

```yml
www:
  build: Dockerfile
  ports:
    - "8080"
```

### Worker linking

This is how you link workers together:

```yml
db:
  image: postgres:latest

www:
  build: Dockerfile
  links:
    - db
```

### Persistent data

This is how you ensure persistent data:

```yml
logs:
  image: tianon/true:latest
  volumes:
    - /var/logs/myservice
  command: /bin/true

www:
  build: Dockerfile
  volumes_from:
    - logs
```

## Management

**Start and stop Hipache:**

```
manage.sh hipache start
manage.sh hipache stop
```

**Start and stop APPs:**

```
manage.sh start [<APP>]
manage.sh stop [<APP>]
```

**Configure APPs:**

```
manage.sh configure <APP> [<KEY> [<VAL>] [--rm]]
```

## [MIT Licensed](https://github.com/Turistforeningen/docker-paas/blob/master/LICENSE)

