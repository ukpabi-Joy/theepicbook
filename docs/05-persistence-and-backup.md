# Task 5 — Persistence & Backup Plan

## What we back up
A `mysqldump` of the `bookstore` database (full schema + data, as portable SQL).
We do not back up raw volume files directly — a SQL dump is portable across
MySQL versions and easy to inspect or move.

## When
Daily, at a low-traffic hour (example: 2 AM server time).

## Where
Initially on the same VM's disk, in a `backups/` folder outside the Docker
volume. For a production setup we would add a step to upload each dump to
object storage (AWS S3), so a full VM loss doesn't also destroy the backups.
This is a stretch goal for this capstone.

## Retention
Keep the last 7 daily dumps, delete anything older, to avoid unbounded disk growth.

## Automation (for the cloud VM, Task 7)
A cron job running this one-line script:

    docker compose exec -T database sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" bookstore' > /home/<user>/backups/bookstore-$(date +\%Y\%m\%d).sql
    find /home/<user>/backups -name "*.sql" -mtime +7 -delete

## Restore procedure
    cat backups/<chosen-file>.sql | docker compose exec -T database sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" bookstore'

## Manual test performed
1. Confirmed baseline count: 54 books.
2. Deleted book id 1 ("28 Summers").
3. Confirmed count dropped to 53, proving real data loss.
4. Restored from a `mysqldump` backup taken beforehand.
5. Confirmed count returned to 54, and book id 1 ("28 Summers") was present again.

## Tested
Yes, manually, on [TODAY'S DATE]. See screenshots (volume inspect,
before/delete/restore counts, container-restart persistence check).
