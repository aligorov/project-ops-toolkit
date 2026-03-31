# Universal Release/Deploy Toolkit

Коротко: это toolkit для полного цикла `release -> remote deploy` с меню, профилями проектов и отдельным secrets-файлом.

## Основные команды

- `scripts/project_ops.sh menu` — интерактивное меню
- `scripts/project_ops.sh release ...` — релиз Docker image и опционально git tag
- `scripts/project_ops.sh deploy ...` — локальный deploy на сервере
- `scripts/project_ops.sh remote-deploy ...` — загрузка toolkit на сервер и запуск deploy по SSH

## Самый простой сценарий

1. Запустить меню:

```bash
/Users/aleksey/Documents/deploy/scripts/project_ops.sh menu
```

2. Выбрать:
- `1` — создать профиль проекта
- `4` — заполнить secrets по `.env.example`
- `5` — сделать релиз в Docker Hub и Git
- `7` — задеплоить на сервер по SSH

После первого заполнения профиля дальше релиз и деплой делаются через меню за несколько вопросов:
- номер сборки или тип bump
- нужен ли git tag
- на какой сервер деплоить
- какой `IMAGE_TAG` ставить

## Что хранится в профиле

Пример: [project.env.example](/Users/aleksey/Documents/deploy/examples/project.env.example)

Профиль содержит:
- локальный путь к репозиторию
- Docker image repo
- настройки git release
- repo URL для deploy
- `APP_DIR` на сервере
- compose settings
- SSH host/user/port
- пути, куда toolkit и secrets будут копироваться на сервер

Secrets хранятся отдельно в `secrets/*.deploy.env` и не передаются в командной строке.

## Что делает релиз

`project_release.sh` умеет:
- bump `VERSION`
- синхронизировать `package.json`
- собирать `docker buildx build --push`
- делать `git commit / push / tag`

Пример прямого запуска:

```bash
/Users/aleksey/Documents/deploy/scripts/project_ops.sh release \
  --config /Users/aleksey/Documents/deploy/examples/project.env.example \
  --bump patch \
  --git
```

## Что делает deploy

`remote_deploy.sh` умеет:
- скопировать toolkit на сервер по SSH
- загрузить профиль проекта
- загрузить secrets-файл
- запустить на сервере `project_ops.sh deploy --config ...`

Сам `project_deploy.sh` на сервере:
- клонирует или обновляет репозиторий
- checkout на branch/tag/commit
- запускает `docker compose pull`
- запускает `docker compose up -d`

## Безопасность

- Не вшивайте GitHub PAT или Docker token в скрипты и профили.
- Для GitHub лучше использовать SSH remote.
- Для Docker используйте `docker login` отдельно, а не храните пароль в toolkit.
- Если токен уже был показан в чате или скриншоте, считайте его скомпрометированным и отзывайте.
- Профиль `--config` выполняется через `source`, значит он должен быть только доверенным.

## Практические замечания

- `deploy` использует `git reset --hard` в `APP_DIR`, поэтому это должна быть dedicated deploy directory.
- Для обновления `package.json` нужен `node`.
- Для релиза нужен `docker buildx`.
- Автоматического rollback нет.
