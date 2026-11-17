<?php
/** Income and expense categories. */
declare(strict_types=1);

/** GET /api/categories */
function categories_list(array $user): void
{
    json_response(query('SELECT * FROM categories WHERE user_id = ? ORDER BY type, name', [$user['id']]));
}

/** POST /api/categories  { name, type } */
function categories_create(array $user): void
{
    $body = request_body();
    $row = query_one('INSERT INTO categories (user_id, name, type) VALUES (?, ?, ?) RETURNING *',
        [$user['id'], field($body, 'name'), field($body, 'type')]);
    json_response($row, 201);
}

/** DELETE /api/categories/{id} (refused while transactions use it: DB-02) */
function categories_delete(array $user, int $id): void
{
    if (execute('DELETE FROM categories WHERE category_id = ? AND user_id = ?', [$id, $user['id']]) === 0) {
        throw new ApiError(404, 'Category not found.');
    }
    no_content();
}
