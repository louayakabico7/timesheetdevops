package tn.esprit.spring.services;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import tn.esprit.spring.entities.AuditLog;
import tn.esprit.spring.repository.AuditLogRepository;

@Service
public class AuditService {

	private static final Logger l = LogManager.getLogger(AuditService.class);

	@Autowired
	AuditLogRepository auditLogRepository;

	public void record(String entityName, String entityId, String action, String details) {
		try {
			AuditLog entry = new AuditLog();
			entry.setEntityName(entityName);
			entry.setEntityId(entityId);
			entry.setAction(action);
			entry.setActor(currentActor());
			entry.setDetails(details);
			auditLogRepository.save(entry);
		} catch (Exception e) {
			l.warn("audit record failed for " + entityName + "/" + entityId + " : " + e.getMessage());
		}
	}

	private String currentActor() {
		try {
			ServletRequestAttributes attrs = (ServletRequestAttributes) RequestContextHolder.getRequestAttributes();
			if (attrs != null) {
				String actor = attrs.getRequest().getHeader("X-Actor");
				if (actor != null && !actor.trim().isEmpty()) {
					return actor.trim();
				}
			}
		} catch (RuntimeException e) {
			return "anonymous";
		}
		return "anonymous";
	}
}
