# aliahan

Aliahan is a local app for planning external courses. The backend uses Gleam and the frontend uses Alpine.js.

It automatically lays out the modules so each course is finished before its deadline and to avoid overlaying modules on the same day. It also allows you to define a slack period before the deadline and rule out weekends. You can also reorder modules in the UI and do some color customization. The changes are persisted in a SQLite database in the root directory.

## Run it

Install Gleam, Erlang, Node.js, and pnpm. Then build the checked-in frontend assets and start the server:

```sh
pnpm install --frozen-lockfile
pnpm run build:css
pnpm run vendor:alpine
gleam run
```

Open <http://127.0.0.1:8000>. You can add data in the UI or define `courses.toml` in the project root before the first run.

Set `ALIAHAN_DATABASE_PATH` to move the SQLite database. The TOML snapshot will follow it with a `.courses.toml` suffix. Set `ALIAHAN_COURSES_TOML_PATH` to choose the snapshot path directly.

## Check it

```sh
gleam format --check src test
gleam check
gleam test
pnpm run check:js
```

<img width="1919" height="1044" alt="Screenshot 2026-03-22 103154" src="https://github.com/user-attachments/assets/909cc370-aaef-4829-9bea-11d25889cdc3" />
<img width="1919" height="1043" alt="Screenshot 2026-03-22 103137" src="https://github.com/user-attachments/assets/8fe5c489-c897-4e0d-b980-e47fa31bf834" />
<img width="1919" height="1044" alt="Screenshot 2026-03-22 103116" src="https://github.com/user-attachments/assets/4cffa006-ad1d-4cd0-82b8-02e84095c87f" />
<img width="1919" height="1044" alt="Screenshot 2026-03-22 103104" src="https://github.com/user-attachments/assets/e91cd1d6-54b9-455d-85d6-d46171ba222d" />
