FUNCTION_NAME ?= arcade-hooks
HANDLER       ?= lambda_handler.main.handler
RUNTIME       ?= python3.13
ROLE_ARN      ?= arn:aws:iam::491085413993:role/arcade-hooks-lambda-role
REGION        ?= us-east-1
CA_PEM        ?= .artifacts/certificates/ca.pem

.PHONY: package deploy

package:
	mkdir -p .artifacts
	rm -rf .artifacts/package .artifacts/function.zip
	uv export --no-dev --no-editable -o .artifacts/requirements.txt
	uv pip install -r .artifacts/requirements.txt \
		--target ./.artifacts/package \
		--python-platform manylinux2014_x86_64 \
		--only-binary=:all: \
		--quiet
	cp -r hooks lambda_handler  .artifacts/package/
	@if [ -f "$(CA_PEM)" ]; then \
		mkdir -p .artifacts/package/certificates; \
		cp $(CA_PEM) .artifacts/package/certificates/ca.pem; \
		echo "Included $(CA_PEM) in package"; \
	fi
	cd .artifacts/package && zip -r ../function.zip . --quiet
	@echo "Built function.zip"

deploy:
	aws lambda create-function \
		--function-name $(FUNCTION_NAME) \
		--runtime $(RUNTIME) \
		--role $(ROLE_ARN) \
		--handler $(HANDLER) \
		--zip-file fileb://.artifacts/function.zip \
		--timeout 30 \
		--region $(REGION)
	@echo "Deployed $(FUNCTION_NAME)"

update:
	aws lambda update-function-code \
		--function-name $(FUNCTION_NAME) \
		--zip-file fileb://.artifacts/function.zip
	@echo "Updated code for $(FUNCTION_NAME)"
