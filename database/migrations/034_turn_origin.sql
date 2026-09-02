ALTER TABLE turns
  ADD COLUMN IF NOT EXISTS origin text NOT NULL DEFAULT 'gui';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'turns_origin_check'
      AND conrelid = 'turns'::regclass
  ) THEN
    ALTER TABLE turns
      ADD CONSTRAINT turns_origin_check
      CHECK (origin IN ('gui', 'terminal'));
  END IF;
END
$$;
