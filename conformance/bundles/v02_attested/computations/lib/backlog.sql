SELECT count(*) AS backlog FROM items WHERE status = 'open' AND day = $day
