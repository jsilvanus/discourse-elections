import { createWidget } from 'discourse/widgets/widget';
import { getOwner } from 'discourse-common/lib/get-owner';
import showModal from 'discourse/lib/show-modal';
import { ElectionStatuses } from '../lib/election';
import { ajax } from 'discourse/lib/ajax';
import { h } from 'virtual-dom';

export default createWidget('election-controls', {
  tagName: 'div.election-controls',
  buildKey: () => `election-controls`,

  defaultState(attrs) {
    return {
      startingElection: false
    }
  },

  toggleNomination() {
    showModal('confirm-nomination', {
      model: {
        topic: this.attrs.topic
      }
    });
  },

  makeStatement() {
    const controller = getOwner(this).lookup('controller:composer');
    const topic = this.attrs.topic;

    controller.open({
      action: 'reply',
      draftKey: 'reply',
      draftSequence: 0,
      topic
    });

    controller.set('model.electionNominationStatement', true);
  },

  manage() {
    showModal('manage-election', {
      model: {
        topic: this.attrs.topic,
        rerender: () => this.scheduleRerender()
      }
    });
  },

  startElection() {
    const topicId = this.attrs.topic.id;

    ajax('/election/start-poll', {type: 'PUT', data: { topic_id: topicId }}).then((result) => {
      if (result.failed) {
        bootbox.alert(result.message);
      } else {
        this.attrs.topic.set('election_status', ElectionStatuses['poll']);
      }

      this.state.startingElection = false;
      this.scheduleRerender();
    })

    this.state.startingElection = true;
    this.scheduleRerender();
  },

  html(attrs, state) {
    const topic = attrs.topic;
    const user = this.currentUser;
    let contents = [];

    if (topic.election_status == ElectionStatuses['nomination'] && topic.election_self_nomination_allowed) {
      contents.push(this.attach('button', {
        action: `toggleNomination`,
        label: `election.nomination.${topic.election_is_nominee ? 'remove.label' : 'add.label'}`,
        className: 'btn-primary toggle-nomination'
      }))
    }

    if (topic.election_is_nominee && !topic.election_made_statement) {
      contents.push(this.attach('button', {
        action: 'makeStatement',
        label: `election.nomination.statement.add`,
        className: 'btn-primary add-statement'
      }))
    }

    if (user && user.is_elections_admin) {
      contents.push(this.attach('button', {
        action: 'manage',
        label: 'election.manage.label',
        className: 'btn-primary manage-election'
      }))
    }

    if (user && user.is_elections_admin && topic.election_status == ElectionStatuses['nomination']) {
      contents.push(this.attach('button', {
        action: 'startElection',
        label: 'election.start',
        className: 'btn-primary start-poll'
      }))

      if (state.startingElection) {
        contents.push(h('div.spinner-container', h('div.spinner.small')))
      }
    }

    return contents;
  }
})
