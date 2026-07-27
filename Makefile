# Every aws call in this file inherits this. Override with: make AWS_PROFILE=other ...
AWS_PROFILE   ?= personal
export AWS_PROFILE

SERVER_REGION ?= ap-southeast-6
WAKE_REGION   := us-east-1
SERVER_STACK  ?= minecraft-server
WAKE_STACK    ?= minecraft-wake
ZONE_STACK    ?= minecraft-zone
SITE_STACK    ?= minecraft-site
HOSTNAME      ?= mc.hamishburke.dev
MINECRAFT_HOSTNAME ?= play.$(HOSTNAME)
PUBLISH_APEX  ?= true

SERVER_PARAMS := infra/params/server.json
WAKE_PARAMS   := infra/params/wake.json
SITE_FILE     := infra/site/index.html

.PHONY: help validate deploy-zone nameservers check-delegation deploy-server \
        deploy-site cutover-site deploy-wake deploy outputs status start stop \
        console logs wake-logs backup-now list-backups destroy

help:
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

tui: ## Open the dashboard — status, start/stop, whitelist, cost
	@./mcctl

validate: ## Check all templates parse server-side
	aws cloudformation validate-template --region $(WAKE_REGION) \
		--template-body file://infra/00-zone.yaml >/dev/null && echo "00-zone.yaml OK"
	aws cloudformation validate-template --region $(SERVER_REGION) \
		--template-body file://infra/02-server.yaml >/dev/null && echo "02-server.yaml OK"
	aws cloudformation validate-template --region $(WAKE_REGION) \
		--template-body file://infra/03-site.yaml >/dev/null && echo "03-site.yaml OK"
	aws cloudformation validate-template --region $(WAKE_REGION) \
		--template-body file://infra/01-wake.yaml >/dev/null && echo "01-wake.yaml OK"

deploy-zone: ## Step 1: create the delegated hosted zone for the subdomain
	aws cloudformation deploy \
		--region $(WAKE_REGION) \
		--stack-name $(ZONE_STACK) \
		--template-file infra/00-zone.yaml \
		--parameter-overrides ServerHostname=$(HOSTNAME)
	@$(MAKE) --no-print-directory nameservers

nameservers: ## Step 2: show the NS records to add in Cloudflare
	@echo ""
	@echo "Add these in Cloudflare DNS for $(HOSTNAME), type NS, DNS only (grey cloud):"
	@echo ""
	@aws cloudformation describe-stacks --region $(WAKE_REGION) \
		--stack-name $(ZONE_STACK) \
		--query "Stacks[0].Outputs[?OutputKey=='NameServers'].OutputValue" \
		--output text | tr ',' '\n' | sed 's/^ */  /'
	@echo ""
	@echo "HostedZoneId (-> infra/params/server.json):"
	@aws cloudformation describe-stacks --region $(WAKE_REGION) \
		--stack-name $(ZONE_STACK) \
		--query "Stacks[0].Outputs[?OutputKey=='HostedZoneId'].OutputValue" \
		--output text | sed 's/^/  /'
	@echo "QueryLogGroupName (-> infra/params/wake.json):"
	@aws cloudformation describe-stacks --region $(WAKE_REGION) \
		--stack-name $(ZONE_STACK) \
		--query "Stacks[0].Outputs[?OutputKey=='QueryLogGroupName'].OutputValue" \
		--output text | sed 's/^/  /'

check-delegation: ## Step 3: verify Cloudflare is delegating to Route 53 yet
	@echo "Nameservers currently answering for $(HOSTNAME):"
	@dig +short NS $(HOSTNAME) | sed 's/^/  /' || true
	@echo ""
	@echo "Expect AWS nameservers (ns-*.awsdns-*). If empty or Cloudflare's,"
	@echo "delegation hasn't propagated yet — wait and re-run."

deploy-server: ## Deploy the Minecraft server stack to Auckland
	aws cloudformation deploy \
		--region $(SERVER_REGION) \
		--stack-name $(SERVER_STACK) \
		--template-file infra/02-server.yaml \
		--capabilities CAPABILITY_IAM \
		--parameter-overrides file://$(SERVER_PARAMS)

deploy-site: ## Deploy/upload the static site; PUBLISH_APEX=true makes it public
	@ZONE_ID=$$(aws cloudformation describe-stacks --region $(WAKE_REGION) \
		--stack-name $(ZONE_STACK) \
		--query "Stacks[0].Outputs[?OutputKey=='HostedZoneId'].OutputValue" --output text); \
	API_DOMAIN=$$(aws cloudformation describe-stacks --region $(WAKE_REGION) \
		--stack-name $(WAKE_STACK) \
		--query "Stacks[0].Outputs[?OutputKey=='PublicApiDomainName'].OutputValue" --output text); \
	aws cloudformation deploy \
		--region $(WAKE_REGION) \
		--stack-name $(SITE_STACK) \
		--template-file infra/03-site.yaml \
		--parameter-overrides HostedZoneId=$$ZONE_ID ServerHostname=$(HOSTNAME) \
			MinecraftHostname=$(MINECRAFT_HOSTNAME) ApiDomainName=$$API_DOMAIN \
			PublishApexAliases=$(PUBLISH_APEX)
	@BUCKET=$$(aws cloudformation describe-stacks --region $(WAKE_REGION) \
		--stack-name $(SITE_STACK) \
		--query "Stacks[0].Outputs[?OutputKey=='SiteBucketName'].OutputValue" --output text); \
	aws s3 cp $(SITE_FILE) s3://$$BUCKET/index.html \
		--content-type text/html --cache-control 'public,max-age=300'
	@DIST=$$(aws cloudformation describe-stacks --region $(WAKE_REGION) \
		--stack-name $(SITE_STACK) \
		--query "Stacks[0].Outputs[?OutputKey=='DistributionId'].OutputValue" --output text); \
	aws cloudfront create-invalidation --distribution-id $$DIST --paths /index.html >/dev/null; \
	echo "Site uploaded; CloudFront invalidation requested."

cutover-site: ## Replace the old EC2 apex A record with the CloudFront website
	@ZONE_ID=$$(aws cloudformation describe-stacks --region $(WAKE_REGION) \
		--stack-name $(ZONE_STACK) \
		--query "Stacks[0].Outputs[?OutputKey=='HostedZoneId'].OutputValue" --output text); \
	PLAY_IP=$$(aws route53 list-resource-record-sets --hosted-zone-id $$ZONE_ID \
		--query "ResourceRecordSets[?Name=='$(MINECRAFT_HOSTNAME).' && Type=='A'].ResourceRecords[0].Value | [0]" \
		--output text); \
	[ "$$PLAY_IP" != "None" ] || { echo "$(MINECRAFT_HOSTNAME) has no A record; aborting"; exit 1; }; \
	OLD_IP=$$(aws route53 list-resource-record-sets --hosted-zone-id $$ZONE_ID \
		--query "ResourceRecordSets[?Name=='$(HOSTNAME).' && Type=='A'].ResourceRecords[0].Value | [0]" \
		--output text); \
	if [ "$$OLD_IP" != "None" ]; then \
		aws route53 change-resource-record-sets --hosted-zone-id $$ZONE_ID \
			--change-batch "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":{\"Name\":\"$(HOSTNAME)\",\"Type\":\"A\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"$$OLD_IP\"}]}}]}" >/dev/null; \
	fi
	@$(MAKE) --no-print-directory deploy-site PUBLISH_APEX=true

deploy-wake: ## Deploy wake-on-Minecraft-query and budget alerts
	aws cloudformation deploy \
		--region $(WAKE_REGION) \
		--stack-name $(WAKE_STACK) \
		--template-file infra/01-wake.yaml \
		--capabilities CAPABILITY_IAM \
		--parameter-overrides file://$(WAKE_PARAMS)

deploy: deploy-wake deploy-server deploy-site ## Deploy API/wake, server, and site stacks

outputs: ## Show stack outputs (server address, instance ID, connect command)
	@aws cloudformation describe-stacks --region $(SERVER_REGION) \
		--stack-name $(SERVER_STACK) \
		--query 'Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}' --output table

INSTANCE_ID = $(shell aws cloudformation describe-stacks --region $(SERVER_REGION) \
	--stack-name $(SERVER_STACK) \
	--query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)

status: ## Is the server up or asleep?
	@aws ec2 describe-instances --region $(SERVER_REGION) \
		--instance-ids $(INSTANCE_ID) \
		--query 'Reservations[0].Instances[0].{State:State.Name,PublicIp:PublicIpAddress}' \
		--output table

start: ## Manually wake the server (normally the DNS trigger does this)
	aws ec2 start-instances --region $(SERVER_REGION) --instance-ids $(INSTANCE_ID)

stop: ## Manually put the server to sleep
	aws ec2 stop-instances --region $(SERVER_REGION) --instance-ids $(INSTANCE_ID)

console: ## Shell onto the instance via Session Manager (no SSH key needed)
	aws ssm start-session --region $(SERVER_REGION) --target $(INSTANCE_ID)

logs: ## Tail the Minecraft server log over SSM
	aws ssm start-session --region $(SERVER_REGION) --target $(INSTANCE_ID) \
		--document-name AWS-StartInteractiveCommand \
		--parameters 'command=["sudo journalctl -u minecraft -f"]'

wake-logs: ## Watch the wake Lambda fire in real time
	aws logs tail /aws/lambda/$$(aws cloudformation describe-stacks --region $(WAKE_REGION) \
		--stack-name $(WAKE_STACK) \
		--query "Stacks[0].Outputs[?OutputKey=='WakeFunctionName'].OutputValue" \
		--output text) --follow --region $(WAKE_REGION)

BUCKET = $(shell aws cloudformation describe-stacks --region $(SERVER_REGION) \
	--stack-name $(SERVER_STACK) \
	--query "Stacks[0].Outputs[?OutputKey=='BackupBucketName'].OutputValue" --output text)

backup-now: ## Force an immediate world archive to S3
	aws ssm send-command --region $(SERVER_REGION) \
		--instance-ids $(INSTANCE_ID) \
		--document-name AWS-RunShellScript \
		--parameters 'commands=["/usr/local/bin/mc-backup.sh"]' \
		--query 'Command.CommandId' --output text

list-backups: ## List world archives in S3
	@aws s3 ls s3://$(BUCKET)/worlds/ --human-readable

destroy: ## Tear down both stacks. The S3 bucket and its worlds are retained.
	@echo "This deletes the EC2 instance and its EBS volume."
	@echo "Run 'make backup-now' first if you have unsaved progress."
	@read -p "Type the stack name to confirm [$(SERVER_STACK)]: " c; \
		[ "$$c" = "$(SERVER_STACK)" ] || { echo "aborted"; exit 1; }
	aws cloudformation delete-stack --region $(WAKE_REGION) --stack-name $(WAKE_STACK)
	aws cloudformation delete-stack --region $(SERVER_REGION) --stack-name $(SERVER_STACK)
