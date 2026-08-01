-- 이 파일은 응답 근거에 웹과 도구와 스킬 종류를 추가한다.

DO $$
DECLARE
    current_definition text;
BEGIN
    SELECT pg_get_constraintdef(oid)
    INTO current_definition
    FROM pg_constraint
    WHERE conrelid = 'turn_response_sources'::regclass
      AND conname = 'turn_response_sources_kind_check';

    IF current_definition IS NULL
       OR position('rag' IN current_definition) = 0
       OR position('database' IN current_definition) = 0
       OR position('file' IN current_definition) = 0
       OR position('web' IN current_definition) = 0
       OR position('tool' IN current_definition) = 0
       OR position('skill' IN current_definition) = 0
    THEN
        IF current_definition IS NOT NULL THEN
            ALTER TABLE turn_response_sources
            DROP CONSTRAINT turn_response_sources_kind_check;
        END IF;

        ALTER TABLE turn_response_sources
        ADD CONSTRAINT turn_response_sources_kind_check CHECK (
            source_kind IN (
                'rag',
                'database',
                'file',
                'web',
                'tool',
                'skill'
            )
        );
    END IF;
END
$$;
