#!/bin/bash
# This shell script converts BigQuery .sql files into PostgreSQL .sql files.

# String replacements are necessary for some queries.
export REGEX_SCHEMA='s/`physionet-data.(mimic_core|mimic_icu|mimic_derived|mimic_hosp).(.+?)`/\1.\2/g'
# Note that these queries are very senstive to changes, e.g. adding whitespaces after comma can already change the behavior.
export REGEX_DATETIME_DIFF="s/DATETIME_DIFF\((.+?),\s?(.+?),\s?(DAY|MINUTE|SECOND|HOUR|YEAR)\)/DATETIME_DIFF(\1,\2,'\3')/g"
# Add necessary quotes to INTERVAL, e.g. "INTERVAL 5 hour" to "INTERVAL '5' hour"
export REGEX_INTERVAL="s/interval\s([[:digit:]]+)\s(hour|day|month|year)/INTERVAL '\1' \2/gI"
# Add numeric cast to ROUND(), e.g. "ROUND(1.234, 2)" to "ROUND( CAST(1.234 as numeric), 2)".
export PERL_REGEX_ROUND='s/ROUND\(((.|\n)*?)\, /ROUND\( CAST\( \1 as numeric\)\,/g'
# Specific queries for some problems that arose with some files.
export REGEX_INT="s/CAST\(hr AS INT64\)/CAST\(hr AS bigint\)/g"
export REGEX_ARRAY="s/GENERATE_ARRAY\(-24, CEIL\(DATETIME\_DIFF\(it\.outtime_hr, it\.intime_hr, HOUR\)\)\)/ARRAY\(SELECT \* FROM generate\_series\(-24, CEIL\(DATETIME\_DIFF\(it\.outtime_hr, it\.intime_hr, HOUR\)\)\)\)/g"
export REGEX_HOUR_INTERVAL="s/INTERVAL CAST\(hr AS INT64\) HOUR/interval \'1\' hour * CAST\(hr AS bigint\)/g"
export CONNSTR='-U postgres -h localhost -p 5500 -d mimic-iv'  # -d mimic


# First, we re-create the postgres-make-concepts.sql file.
echo "\echo ''" > postgres/postgres-make-concepts.sql

# Now we add some preamble for the user running the script.
echo "\echo '==='" >> postgres/postgres-make-concepts.sql
echo "\echo 'Beginning to create materialized views for MIMIC database.'" >> postgres/postgres-make-concepts.sql
echo "\echo '"'Any notices of the form  "NOTICE: materialized view "XXXXXX" does not exist" can be ignored.'"'" >> postgres/postgres-make-concepts.sql
echo "\echo 'The scripts drop views before creating them, and these notices indicate nothing existed prior to creating the view.'" >> postgres/postgres-make-concepts.sql
echo "\echo '==='" >> postgres/postgres-make-concepts.sql
echo "\echo ''" >> postgres/postgres-make-concepts.sql
echo "\echo 'Top level files..'" >> postgres/postgres-make-concepts.sql

# Iterate through each concept subfolder, and:
# (1) apply the above regular expressions to update the script
# (2) output to the postgres subfolder
# (3) add a line to the postgres-make-concepts.sql script to generate this table

# order of the folders is important for a few tables here:
# * firstday should go last
# * scores (sofa et al) depends on labs
# * sepsis depends on score (sofa.sql in particular)
# * organfailure depends on measurement
# the order *only* matters because we are inserting into the postgres-make-concepts.sql file in the loop
for d in demographics measurement comorbidity medication organfailure treatment score sepsis firstday score sepsis;
do
    mkdir -p "postgres/${d}"
    echo -n "${d}:"
    echo "" >> postgres/postgres-make-concepts.sql
    echo "-- ${d}" >> postgres/postgres-make-concepts.sql
    for fn in `ls $d`;
    do
        # only run SQL queries
        if [[ "${fn: -4}" == ".sql" ]]; then
            # table name is file name minus extension
            tbl="${fn::-4}"

            # Create first_day_lab after measurements done and before it is used by scores.
            if [[ "${tbl}" == "charlson" ]]; then
                # Generate some tables first to prevent conflicts during processing.
                # Have to replace column names. Probably a mistake in the original SQL script.
                export REGEX_LAB_1="s/abs_basophils/basophils_abs/g"
                export REGEX_LAB_2="s/abs_eosinophils/eosinophils_abs/g"
                export REGEX_LAB_3="s/abs_lymphocytes/lymphocytes_abs/g"
                export REGEX_LAB_4="s/abs_monocytes/monocytes_abs/g"
                export REGEX_LAB_5="s/abs_neutrophils/neutrophils_abs/g"
                export REGEX_LAB_6="s/atyps/atypical_lymphocytes/g"
                export REGEX_LAB_7="s/imm_granulocytes/immature_granulocytes/g"
                export REGEX_LAB_8="s/metas/metamyelocytes/g"
                { echo "DROP TABLE IF EXISTS first_day_lab; CREATE TABLE first_day_lab AS "; cat firstday/first_day_lab.sql;} | sed -r -e "${REGEX_DATETIME_DIFF}" | sed -r -e "${REGEX_SCHEMA}" | sed -r -e "${REGEX_INTERVAL}" | sed -r -e "${REGEX_LAB_1}" | sed -r -e "${REGEX_LAB_2}" | sed -r -e "${REGEX_LAB_3}" | sed -r -e "${REGEX_LAB_4}" | sed -r -e "${REGEX_LAB_5}" | sed -r -e "${REGEX_LAB_6}" | sed -r -e "${REGEX_LAB_7}" | sed -r -e "${REGEX_LAB_8}" | perl -0777 -pe "${PERL_REGEX_ROUND}" > "postgres/${d}/first_day_lab.sql"
            fi

            # skip first_day_sofa as it depends on other firstday queries, also skipped already processed tables.
            if [[ "${tbl}" == "first_day_sofa" ]] || [[ "${tbl}" == "icustay_times" ]] || [[ "${tbl}" == "weight_durations" ]] || [[ "${tbl}" == "urine_output" ]] || [[ "${tbl}" == "kdigo_uo" ]] || [[ "${tbl}" == "first_day_lab" ]]; then
                continue
            fi
            echo -n " ${tbl} .."
            { echo "DROP TABLE IF EXISTS ${tbl}; CREATE TABLE ${tbl} AS "; cat "${d}/${fn}";} | sed -r -e "${REGEX_ARRAY}" | sed -r -e "${REGEX_HOUR_INTERVAL}" | sed -r -e "${REGEX_INT}" | sed -r -e "${REGEX_DATETIME_DIFF}" | sed -r -e "${REGEX_SCHEMA}" | sed -r -e "${REGEX_INTERVAL}" | perl -0777 -pe "${PERL_REGEX_ROUND}" > "postgres/${d}/${fn}"

            # TODO: do not output order sensitive tables here
            echo "\i ${d}/${fn}" >> postgres/postgres-make-concepts.sql
        fi
    done
    echo " done!"
done
