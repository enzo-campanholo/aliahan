# aliahan

This is a completely vibecoded project to help me manage my external courses. The backend is in Gleam and the frontend is done in AlpineJS. You can run it locally with 'gleam run'. You can also define a toml file and put it in the root directory if you do not want to add the vendors, courses, and modules through the UI.

It automatically lays out the modules so each course is finished before its deadline and to avoid overlaying modules on the same day. It also allows you to define a slack period before the deadline and rule out weekends. You can also reorder modules in the UI and do some color customization. The changes are persisted in a SQLite database in the root directory.

<img width="1919" height="1044" alt="Screenshot 2026-03-22 103154" src="https://github.com/user-attachments/assets/909cc370-aaef-4829-9bea-11d25889cdc3" />
<img width="1919" height="1043" alt="Screenshot 2026-03-22 103137" src="https://github.com/user-attachments/assets/8fe5c489-c897-4e0d-b980-e47fa31bf834" />
<img width="1919" height="1044" alt="Screenshot 2026-03-22 103116" src="https://github.com/user-attachments/assets/4cffa006-ad1d-4cd0-82b8-02e84095c87f" />
<img width="1919" height="1044" alt="Screenshot 2026-03-22 103104" src="https://github.com/user-attachments/assets/e91cd1d6-54b9-455d-85d6-d46171ba222d" />
