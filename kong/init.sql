-- Banco extra do Konga, criado no primeiro start do postgres-kong.
--
-- O container do Kong usa o banco `kong` (POSTGRES_DB); o Konga precisa de um
-- banco separado só dele. O usuário `kong` é o superusuário (POSTGRES_USER),
-- então o GRANT é redundante — fica por paridade com o projeto de referência.
--
-- Usado pelo docker-compose (bind mount em /docker-entrypoint-initdb.d/).
-- No Kubernetes o mesmo SQL está inline no ConfigMap de k8s/postgres-kong.yaml.

CREATE DATABASE konga;
GRANT ALL PRIVILEGES ON DATABASE konga TO kong;
